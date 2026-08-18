# Reference: Storage — Frostlink

## Storage Class

Default storage class: **`openebs-zfs`** (provisioner: `zfs.csi.openebs.io`)

- Pool: `openebs` ZFS dataset on the boot volume block device
- fstype: `zfs`
- Access mode: `ReadWriteOnce`
- Volume binding mode: `WaitForFirstConsumer`
- Volume expansion: supported (`allowVolumeExpansion: true`)
- Reclaim policy: `Delete`

```yaml
persistence:
    data:
        type: persistentVolumeClaim
        storageClass: openebs-zfs
        accessMode: ReadWriteOnce
        size: 5Gi
```

`openebs-zfs` is the default class — `storageClassName` can be omitted if you accept the default.

## VolumeSnapshotClass

`zfs-snapshotclass` — driver `zfs.csi.openebs.io`, deletion policy `Delete`. Used by Kopiur for snapshot-based backups.

## Backups via Kopiur

Kopiur is deployed in `kopiur-system`. It snapshots PVCs via ZFS and pushes to **Cloudflare R2** (`ClusterRepository: r2`).

### Component template

All stateful apps use the shared component at `kubernetes/components/kopiur/`. Add to `ks.yaml`:

```yaml
spec:
    components:
        - ../../../../components/kopiur
```

And in `postBuild.substitute`:

```yaml
APP: myapp                          # required — names all Kopiur resources
KOPIUR_CAPACITY: 5Gi               # PVC size (default 5Gi)
KOPIUR_STORAGECLASS: openebs-zfs   # default
KOPIUR_SNAPSHOTCLASS: zfs-snapshotclass  # default
KOPIUR_CACHE_CAPACITY: 2Gi         # mover cache (default 2Gi — do not go lower)
KOPIUR_ACCESSMODES: ReadWriteOnce  # default
```

The component creates 4 resources: `PersistentVolumeClaim`, `SnapshotPolicy`, `SnapshotSchedule`, `Restore`.

### Schedule and retention

Component defaults: hourly snapshots (`H * * * *`, 2m jitter), retention 3 latest / 24 hourly /
7 daily / 4 weekly / 3 monthly, `copyMethod: Snapshot` (ZFS snapshots, not full copies).

Both cadence and retention are per-app overridable from `postBuild.substitute` —
`KOPIUR_SCHEDULE`, `KOPIUR_KEEP_LATEST/HOURLY/DAILY/WEEKLY/MONTHLY`. Current overrides:

| App | Schedule | Why |
| --- | --- | --- |
| `vm-single` | `H 3 * * *`, 1/0/7/0/0 | VictoriaMetrics' TSDB rewrites its parts continuously, so hourly snapshots deduplicated poorly and dominated churn in the R2 repository. Metrics are the most reconstructible data here — daily, 7 deep, is enough. |
| `apoci` | `H */6 * * *` | Registry blobs are content-addressed and effectively immutable, so hourly bought almost nothing over 6-hourly. Retention left at the component default (~30 restore points). |

### The R2 credential key is unrecoverable if repointed — read before editing

`kubernetes/apps/kopiur-system/kopiur/repository/externalsecret.yaml` pulls `KOPIA_PASSWORD`
from the 1Password item **`kopiur-frostlink`**. The `-frostlink` suffix is load-bearing: the
item plainly named `kopiur` belongs to **Artemis**. Pointing this key at the wrong item syncs
cleanly and only fails later, at connect time, with `invalid repository password`.

A kopia repository cannot be opened without its original password and does not store it, so a
wrong-but-valid-looking value here is **unrecoverable**. Compounding it: an *erroring*
ExternalSecret leaves its target Secret untouched, so a broken ES is often the only thing
preserving the live credential — "fixing" the error is what destroys it.

**Never repoint this key without first confirming the candidate actually opens the repository.**
This was learned the hard way on 2026-08-05; recovery only worked because 1Password still had
the deleted item in its trash.

### barman WAL retention

The shared Postgres cluster archives WAL to the same bucket under `barman/`
(`kubernetes/apps/database/postgres/cluster/objectstore.yaml`). `retentionPolicy: 14d` — ample
PITR for a single-node homelab VPS, and it roughly halves both the `barman/` footprint and its
object count. WAL segments dominate the bucket's *object count* even though they are a small
share of its bytes. `data.compression` is `gzip`: the CRD enum is `[bzip2, gzip, lz4, snappy]`,
so zstd is not available there (it is for `wal.compression`, which uses it).

### Known quirks

- **`inheritSecurityContextFrom: pvcConsumer: {}`** is required in `SnapshotPolicy` — the mover must inherit the UID from the consuming app pod, or it gets permission errors writing to the volume. The component template already includes this. **`pvcConsumer` is backup-only** — the webhook rejects it on a `Restore` CR. If you need security context inheritance on a manual Restore, use `workloadSelector: { podSelector: { matchLabels: { app.kubernetes.io/name: <app> } } }` instead.
- **Mover cache must be ≥ 2Gi** — the Kopiur default of 1Mi causes "disk quota exceeded" failures. The component template defaults to 2Gi; only override if you need more.
- **PVC/Restore annotation `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`** — creates the resource when absent, then leaves it alone (`spec.dataSourceRef` is immutable once bound). It was `ignore` until 2026-08-18, which skipped the apply entirely and meant Flux could neither create these on a fresh cluster nor recreate them for a restore. See the Restore section below before changing it.
- **Restore PVC on first deploy** — the PVC uses `dataSourceRef` pointing to the `Restore` CRD; Kopiur populates it from R2 once a pod claims it. `onMissingSnapshot: Continue` means a missing snapshot doesn't block PVC creation — which is exactly why a stale `Restore` CR can hand back an empty volume and call it success. See the Restore section.

## Restore

Use `just kube restore <ns> <ks> <claim>` (add a snapshot offset as a 4th arg to go back
further). It encodes every constraint below and, critically, **asserts the restore actually
came from a snapshot** before declaring success. Do not hand-roll the sequence.

The restore path was exercised end-to-end for the first time on 2026-08-18 against
`matrix/continuwuity` (0.49Gi, 2662 files). It **did not work on the first attempt** — the
three defects below were all latent until then.

### The Restore CR pins its snapshot resolution at creation — permanently

`Restore.status.resolved.pinnedAt` / `.resolution` are decided once, when the CR is created,
and never re-evaluated. A `Restore` created on an app's first deploy — before any snapshot
exists — pins `resolution: NoSnapshot` **forever**. Because the component sets
`policy.onMissingSnapshot: Continue`, every later restore then:

- provisions an **empty** volume,
- runs **no** mover Job at all,
- and reports `phase: Completed`, `Ready: True`.

The app starts on the empty volume and initialises a fresh database. This is a silent
data-loss failure that looks like success. Confirmed on continuwuity, whose Restore was
created 2026-07-09 and had been poisoned for 40 days.

**Always delete and recreate the `Restore` CR before restoring** so it re-resolves against the
current `SnapshotPolicy`. A healthy restore shows `status.resolved.resolution: Snapshot`; if it
says `NoSnapshot`, the volume is empty — stop and use the retained PV.

### `ssa: IfNotPresent`, never `ssa: ignore`

The component's PVC and Restore carry `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`.

`Ignore` (used until 2026-08-18) makes kustomize-controller skip the resource **entirely** —
it logs `"PersistentVolumeClaim/<ns>/<app>":"skipped"`. That means Flux never creates it on a
fresh cluster and never recreates it after a delete-to-restore. The PVCs that exist today were
created by `just kube apply-ks`, which is a plain server-side apply and ignores the
annotation — not by Flux. A from-scratch Flux bootstrap would have left every Kopiur-backed
app without a PVC.

`IfNotPresent` creates the resource when absent and leaves it alone once it exists, which is
what was actually wanted. Do not drop the annotation entirely: `spec.dataSourceRef` is
immutable once bound, so a plain apply is rejected — and because Flux applies a Kustomization
atomically, that one rejection blocks the **entire** Kustomization.

> Corollary: **`just kube apply-ks` fails on any app with a bound Kopiur PVC**, because it
> bypasses the annotation and tries to add `dataSourceRef` to a bound claim. Let Flux apply
> those, or filter the PVC out of the render.

### `WaitForFirstConsumer` means a restore needs a consumer

`openebs-zfs` is `volumeBindingMode: WaitForFirstConsumer`. A new PVC sits `Pending` with
`Used By: <none>` and the populator does nothing until a pod claims it. **The workload must be
scaled back up to drive the restore** — it cannot run with the app at zero, which is the
opposite of the usual instinct.

Side effect: the real app is the first consumer, so it starts mutating the volume the moment
the restore lands. To inspect a restored volume pristine, use a throwaway consumer pod
(`just kube browse-pvc`) as the first consumer instead of the app.

### Always retain the old volume first

Flip the PV to `Retain` before deleting the PVC — the `just kube restore` recipe does this
automatically. The storage class reclaim policy is `Delete`, so without it the old volume is
destroyed the instant the PVC goes away, and the empty-restore failure above becomes
unrecoverable. This is the only reason the 2026-08-18 test was not data loss.

After verifying the restore, reclaim the retained volume. **Removing the PV is not enough** —
the `ZFSVolume` CR in `openebs-system` (and its dataset) is orphaned separately and must be
removed too, or the space stays leaked. The recipe prints the exact command when it finishes.

### Observed timings

0.49Gi / 2662 files, single-node ARM to Cloudflare R2:

| Phase | Time |
| --- | --- |
| On-demand snapshot (backup) | ~49s |
| Consumer created -> PVC `Bound` | **54s** |
| Mover Job runtime | ~38s |
| PVC `Bound` -> app serving | ~4s |

Roughly ~16s fixed overhead plus transfer. Do not extrapolate linearly to large volumes — this
was a metadata-heavy RocksDB workload where small-file overhead dominates.

## Why vm-single uses `existingClaim`

`server.persistentVolume.existingClaim` binds the victoria-metrics-single chart to the PVC the
kopiur component creates, instead of letting the chart mint one from a StatefulSet
`volumeClaimTemplate`.

A `volumeClaimTemplate` PVC cannot carry `spec.dataSourceRef`, so until 2026-08-18 vm-single
was backed up by Kopiur but **could never be restored by the populator** — the StatefulSet
would always recreate the claim from its own template. Setting `existingClaim` makes the chart
drop `volumeClaimTemplates` entirely and emit a plain `volumes[]` reference (verified against
chart 0.44.0).

Two things to know when touching this:

- `volumeClaimTemplates` is immutable on a live StatefulSet, so the migration required deleting
  the StatefulSet (orphaning its pods) and letting Helm recreate it. The PVC has no
  `ownerReferences` and survives that untouched.
- The claim is still named `server-volume-victoria-metrics-server-0` **on purpose**. The kopia
  source identity is `<namespace>-<KOPIUR_APP>@<namespace>:/pvc/<KOPIUR_APP>`, so renaming
  `KOPIUR_APP` would start a fresh snapshot lineage and orphan the existing dailies in R2 with
  nothing to prune them.

## Known alerting gap: KopiurBackupStale

The `KopiurBackupStale` rule (VMRule `kopiur-system/kopiur-controller`) uses a flat threshold:

```promql
time() - kopiur_policy_last_backup_success_timestamp_seconds > 21600
```

6h, applied to every policy regardless of its schedule. `vm-single` is deliberately on
`H 3 * * *` (daily), so it is "stale" by that definition for ~18h of every day and the alert
fires daily and permanently. The backups are healthy. Until the rule derives its threshold from
each policy's own schedule, this alert is noise — which is worse than useless, because it masks
a real backup failure.

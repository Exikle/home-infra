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
It is the **only** class on this cluster; there is no RWX class and no second tier.

### Where this differs from Artemis, and why the rules do not transfer

Both repos have a `storage.md` describing kopiur. The kopiur semantics are shared; the storage
substrate is not, and two of the differences change operational rules outright:

| | Frostlink | Artemis |
| --- | --- | --- |
| Class | `openebs-zfs` (only class) | `ceph-block` (only class — `ceph-filesystem` does not exist) |
| Provisioner | `zfs.csi.openebs.io`, node-local ZFS | `rook-ceph.rbd.csi.ceph.com`, 3× replicated RBD |
| `volumeBindingMode` | **`WaitForFirstConsumer`** | **`Immediate`** |
| Reclaim policy | `Delete` | `Delete` |
| kopiur backend | Cloudflare R2 (`ClusterRepository/r2`) | NFS on TrueNAS (`ClusterRepository/atlas`) |
| kopiur substitute var | `${KOPIUR_APP}` | `${APP}` |
| kopia identity | `<ns>-<policy>@<ns>` | `<policy>@<ns>` |
| Repo secret reach | `credentialProjection` from `kopiur-system` | a `kopiur/secret` component per namespace |
| `ssa: ignore` on kopiur resources | **none** (removed 2026-08-18) | on the `Restore` only |

The binding-mode row is the one that bites. **"The workload must be scaled back up to drive the
restore" is a `WaitForFirstConsumer` rule and is true only here.** On Artemis a PVC provisions
immediately with no consumer, so a restore runs with the app at zero — the usual instinct, and the
opposite of what this file says below. Reading either repo's restore procedure against the other
cluster produces a confidently wrong sequence.

Deleting a volume also has two layers here and one there: on Frostlink a `ZFSVolume` CR in
`openebs-system` outlives a removed PV and must be deleted separately (§ Always retain the old
volume first); on Artemis the RBD image is reclaimed by the CSI driver with the PV.

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

| Variable                | Default             | What it names                                    |
| ----------------------- | ------------------- | ------------------------------------------------ |
| `KOPIUR_APP`            | **none — required** | every Kopiur resource: PVC, SnapshotPolicy, SnapshotSchedule, Restore |
| `KOPIUR_CAPACITY`       | `5Gi`               | PVC size                                          |
| `KOPIUR_STORAGECLASS`   | `openebs-zfs`       | PVC and mover-cache class                         |
| `KOPIUR_SNAPSHOTCLASS`  | `zfs-snapshotclass` | `volumeSnapshotClassName`                         |
| `KOPIUR_CACHE_CAPACITY` | `2Gi`               | mover cache — do not go lower                     |
| `KOPIUR_ACCESSMODES`    | `ReadWriteOnce`     | PVC access modes                                  |
| `KOPIUR_SCHEDULE`       | `H * * * *`         | `SnapshotSchedule` cron (jitter `2m`, `America/Toronto`) |
| `KOPIUR_KEEP_LATEST/HOURLY/DAILY/WEEKLY/MONTHLY` | `3` / `24` / `7` / `4` / `3` | retention |

**The variable is `KOPIUR_APP`, not `APP`.** Every resource in `components/kopiur/` interpolates
`${KOPIUR_APP}` with no default, so an app that substitutes `APP` instead renders literal
`${KOPIUR_APP}` names and the Kustomization fails on the invalid resource name. Artemis's
equivalent component uses plain `${APP}` — a `postBuild.substitute` block copied between the two
repos is wrong in exactly this one line, in both directions.

The component creates 4 resources: `PersistentVolumeClaim`, `SnapshotPolicy`, `SnapshotSchedule`, `Restore`.

Three behaviours the component enables that nothing else documents:

- **`credentialProjection.enabled: true`** on both the `SnapshotPolicy` and the `Restore`, matched
  by `credentialProjection.allowed: true` on `ClusterRepository/r2`. The repository Secret lives in
  `kopiur-system`; projection is what lets a mover in `fediverse` or `matrix` read it without a
  copy of the Secret in every namespace. Artemis solves the same problem the opposite way — a
  `components/kopiur/secret` per namespace, because its mover uses namespace-local `envFrom`. If
  projection is ever disabled here, every backed-up namespace needs its own copy of the R2 secret.
- **A `preflight` check, `backend-reachable`** (`expr: repository.backendReachable`, `timeout: 30m`).
  It gates the mover only when the health probe has **positively observed** R2 as unreachable;
  `backendReachable` is true when the probe is disabled or has no evidence, so it fails open.
  Purpose is to hold a backup rather than mark it `Failed` during an R2 blip — which is why the
  timeout is generous.
- **Weekly quick verification** — `verification.quick.schedule: H 4 * * 0`, jitter 30m, timezone
  inherited from the repository's `scheduleDefaults`. This is a blob-level verify, not a restore
  drill; it shows up as the `LAST-VERIFIED` column in `kubectl get snapshotpolicy -A`. A
  `LAST-VERIFIED` older than ~8 days means verification is not running, even if backups are.

### Schedule and retention

Component defaults: hourly snapshots (`H * * * *`, 2m jitter), retention 3 latest / 24 hourly /
7 daily / 4 weekly / 3 monthly, `copyMethod: Snapshot` (ZFS snapshots, not full copies).
Artemis's component keeps 30 daily / 8 weekly / 6 monthly with no `keepLatest` or `keepHourly` —
it writes to NFS on a 41 TB array, this one writes to a metered R2 bucket. The two retention
policies are deliberately different; do not align them.

The fleet is five policies (`kubectl get snapshotpolicy -A`): `fediverse/gotosocial`,
`fediverse/apoci-data`, `matrix/continuwuity`, `observability/server-volume-victoria-metrics-server-0`,
`towonel/towonel`. `towonel` was added 2026-08-18 and runs on the hourly default.

Both cadence and retention are per-app overridable from `postBuild.substitute` —
`KOPIUR_SCHEDULE`, `KOPIUR_KEEP_LATEST/HOURLY/DAILY/WEEKLY/MONTHLY`. Current overrides:

| App | Schedule | Why |
| --- | --- | --- |
| `vm-single` | `H 3 * * *`, 1/0/7/0/0 | VictoriaMetrics' TSDB rewrites its parts continuously, so hourly snapshots deduplicated poorly and dominated churn in the R2 repository. Metrics are the most reconstructible data here — daily, 7 deep, is enough. |
| `apoci` | `H */6 * * *` | Registry blobs are content-addressed and effectively immutable, so hourly bought almost nothing over 6-hourly. Retention left at the component default (~30 restore points). |

> Changing a `KOPIUR_SCHEDULE` means updating that policy's branch in `KopiurPolicyBackupStale`
> too — see "Backup staleness alerting is per-policy" below. Nothing derives it automatically,
> and the failure mode is a permanently-firing alert nobody reads.

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

- **The two CRs inherit their mover UID from different places, and that is not interchangeable.**
  `SnapshotPolicy` uses `inheritSecurityContextFrom: pvcConsumer: {}` — it takes the UID from the
  pod currently consuming the PVC, which during a backup is the running app. `Restore` uses
  `inheritSecurityContextFrom: snapshot: {}` — it replays the UID/GID recorded **on the backup
  snapshot**, which needs no live pod. That is the whole point: during a restore the PVC is often
  unbound and there is no consumer to read a UID from. Both are already in the component template.
  `pvcConsumer` is backup-only; the webhook rejects it on a `Restore`. `workloadSelector` works on
  either but should not be needed — reach for it only when a snapshot predates the UID being
  recorded. Getting this wrong writes the restored tree as uid 1000 and the app cannot open its own
  data.
- **`inheritSecurityContextFrom` only sees a UID the pod spec pins.** Per the CRD's own field
  documentation: a UID that comes from the image's `USER` line is invisible in the pod spec and
  cannot be inherited, and the mover then silently runs as its **own** image's UID. Set
  `securityContext`/`podSecurityContext` alongside it — they override field-wise and act as the
  fallback when no workload pod resolves.
- **Mover cache must be ≥ 2Gi** — the Kopiur default of 1Mi causes "disk quota exceeded" failures. The component template defaults to 2Gi; only override if you need more.
- **No `kustomize.toolkit.fluxcd.io/ssa` annotation on the PVC/Restore** — Flux applies them normally; a rendered PVC matching the bound one is a no-op. It was `ssa: ignore` until 2026-08-18, which skipped the apply entirely so Flux could neither create these on a fresh cluster nor recreate them for a restore. Do not re-add it — see the Restore section for the prerequisite that makes going annotation-free safe.
- **Restore PVC on first deploy** — the PVC uses `dataSourceRef` pointing to the `Restore` CRD; Kopiur populates it from R2 once a pod claims it. `onMissingSnapshot: Continue` means a missing snapshot doesn't block PVC creation — which is exactly why a stale `Restore` CR can hand back an empty volume and call it success. See the Restore section.
- **The populator only ever acts on an UNBOUND claim.** Once the PVC is bound, the Restore reports
  `Ready=True` with reason **`TargetAlreadyBound`** and does nothing at all — no prime PVC, no
  mover, the live volume untouched. `fediverse/apoci-data` has sat in exactly this state since
  2026-07-21. That is the correct and safe behaviour, but it means **editing a `Restore` and
  waiting will never restore anything**: the PVC must be deleted so it is re-created unbound,
  keeping its `dataSourceRef`. `just kube restore` is the sequence that does this safely.

## Restore

Use `just kube restore <ns> <ks> <claim>` (add a snapshot offset as a 4th arg to go back
further). It encodes every constraint below and, critically, **asserts the restore actually
came from a snapshot** before declaring success. Do not hand-roll the sequence. It has been
exercised end to end against continuwuity, vm-single, and gotosocial.

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
current `SnapshotPolicy`. There are three states, not two — read them like this:

| `status.resolved.resolution` | Meaning |
| ---------------------------- | --------- |
| `Snapshot`                   | healthy — it resolved against a real snapshot and would restore data |
| `NoSnapshot`                 | **poisoned** — the volume is empty. Stop and use the retained PV |
| _absent_, `TargetAlreadyBound` | healthy — the PVC is already bound so there was nothing to populate, and nothing is pinned. It resolves fresh when a restore is actually needed |

The third row is what remediating a poisoned `Restore` looks like while its PVC is still bound:
deleting and recreating the CR clears the `NoSnapshot` pin, and because the live PVC needs no
populating, the new CR settles unpinned rather than resolving to `Snapshot`. Do not read the
absent field as a failure — the danger was never "no resolution", it was a resolution **pinned**
to `NoSnapshot`.

Audit the whole fleet in one command — the pin is invisible from `phase`, which reads `Completed`
either way:

```bash
kubectl get restore -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
RESOLUTION:.status.resolved.resolution,PINNED:.status.resolved.pinnedAt,PHASE:.status.phase
```

State as of 2026-08-21:

| Restore | `resolution` | Meaning |
| --- | --- | --- |
| `fediverse/gotosocial` | `Snapshot` | healthy — would restore real data |
| `matrix/continuwuity` | `Snapshot` | healthy |
| `observability/server-volume-victoria-metrics-server-0` | `Snapshot` | healthy |
| `fediverse/apoci-data` | _(none)_ | never resolved — `TargetAlreadyBound`, the PVC was already bound |
| `towonel/towonel` | _(none)_ | remediated 2026-08-22 — was `NoSnapshot`, pinned 2026-08-18 before its first snapshot |

`towonel/towonel` was the live instance of the failure this section describes: its policy had been
snapshotting hourly since 2026-08-18 while its `Restore` would still have provisioned an empty
volume and reported success. Remediated 2026-08-22 by deleting the CR and letting Flux recreate
it — the PVC stayed `Bound` and the pod never restarted. Note the Kustomization's interval is
`1h`, so force a reconcile rather than waiting. **Every app onboarded through the kopiur
component starts in this state** — the `Restore` is created on first deploy, before any snapshot
exists — so treat `NoSnapshot` as the default, not the exception.

### No `ssa:` annotation — and why the old one was wrong

The component's PVC and Restore carry **no** `kustomize.toolkit.fluxcd.io/ssa` annotation, the
same as upstream (onedr0p and the rest of the kubesearch cohort). Flux applies them normally.
That works because a rendered PVC identical to the bound one is a no-op apply — nothing
mutates, so nothing is rejected.

It was `ssa: ignore` until 2026-08-18. `Ignore` makes kustomize-controller skip the resource
**entirely** — it logs `"PersistentVolumeClaim/<ns>/<app>":"skipped"`. Consequences:

- Flux never created these on a fresh cluster, and never recreated them after a
  delete-to-restore. The PVCs that existed were created by `just kube apply-ks` (a plain
  server-side apply, which ignores the annotation), **not** by Flux. A from-scratch Flux
  bootstrap would have left every Kopiur-backed app without a PVC.
- Capacity changes to `KOPIUR_CAPACITY` in git would never reach the cluster.

`IfNotPresent` was an intermediate step: it fixes creation but still never reconciles an
existing claim, so a capacity bump would silently do nothing. Dropping the annotation entirely
is correct — but only once **every** live PVC already matches its rendered manifest.

> **The prerequisite is real.** `spec.dataSourceRef` is immutable once bound, and Flux applies
> a Kustomization atomically, so one rejected PVC blocks the *entire* Kustomization (a safe
> failure — the app keeps running — but nothing else in that Kustomization reconciles either).
> On 2026-08-18 both `vm-single` and `gotosocial` had PVCs predating the component and lacking
> `dataSourceRef`; each had to be recreated through `just kube restore` before the annotation
> could come off. Check with a server dry-run before touching this:
>
> ```
> just kube render-local-ks <ns> <app> | kubectl apply --server-side \
>   --force-conflicts --field-manager=kustomize-controller --dry-run=server -f -
> ```

> **Removing it from git is not enough.** kustomize-controller reads the annotation off the
> **live object**, not just the rendered manifest, so a resource still carrying a stale
> `ssa: ignore` keeps being skipped forever — silently, since the Kustomization still reports
> Ready. Strip it from the live objects with a server-side apply that no longer includes the
> field (`just kube apply-ks <ns> <app>` does exactly that). Confirm with:
>
> ```
> kubectl -n flux-system logs deploy/kustomize-controller --since=2m \
>   | grep -oE '"PersistentVolumeClaim/[^"]*":"[a-z]*"'
> ```
>
> `unchanged`/`configured` means Flux is managing it; `skipped` means it is still ignored.

Because a bound PVC is now a no-op apply, `just kube apply-ks` works on Kopiur-backed apps
again. Any future app whose PVC is created outside the component will reintroduce the problem —
the fix is always to recreate that PVC through the restore path, never to re-add the annotation.

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

All three restores below were run on 2026-08-18, single-node ARM to Cloudflare R2. The
end-to-end column is the whole `just kube restore` run: scale down, delete, Flux recreate,
repopulate, roll out.

| App | Size / files | Backup | Restore (end to end) |
| --- | --- | --- | --- |
| `matrix/continuwuity` | 0.49Gi / 2662 | ~49s | 54s to `Bound`, +4s serving |
| `observability/vm-single` | 3.18Gi / — | ~53s | ~2m |
| `fediverse/gotosocial` | 0.37Gi / 3163 | ~58s | **1m14s** |

Roughly ~16s of fixed overhead (prime PVC, Job scheduling, kopia connect) plus transfer. Do
not extrapolate linearly — continuwuity and gotosocial are metadata-heavy workloads with
thousands of small files, where per-file overhead dominates over raw bytes. Note that
gotosocial moved *more* files than continuwuity in less time despite being smaller, because
media files are large and contiguous where RocksDB SSTs are not.

Verification results, for confidence in the path:

- **gotosocial**: 3163 files, **all 3163 byte-identical** by sha256 — zero missing, zero extra,
  zero mismatched. The cleanest possible result.
- **continuwuity**: all 1768 media files byte-identical; the only same-path hash difference
  across the volume was `/CURRENT`, RocksDB's manifest pointer, plus `.sst`/`.log` churn from
  compaction after the app reopened the DB.
- **vm-single**: `rowsCount: 16948801650` after restore, storage opened clean, queries served.

## Why vm-single uses `existingClaim`

`server.persistentVolume.existingClaim` binds the victoria-metrics-single chart to the PVC the
kopiur component creates, instead of letting the chart mint one from a StatefulSet
`volumeClaimTemplate`.

A `volumeClaimTemplate` PVC cannot carry `spec.dataSourceRef`, so until 2026-08-18 vm-single
was backed up by Kopiur but **could never be restored by the populator** — the StatefulSet
would always recreate the claim from its own template. Setting `existingClaim` makes the chart
drop `volumeClaimTemplates` entirely and emit a plain `volumes[]` reference (verified against
chart 0.44.0, still true at 0.45.0 — the live `victoria-metrics-server` StatefulSet reports no
`volumeClaimTemplates`). Re-check this after any major chart bump: the failure is silent, because
a re-introduced template just quietly mints a second claim.

Two things to know when touching this:

- `volumeClaimTemplates` is immutable on a live StatefulSet, so the migration required deleting
  the StatefulSet (orphaning its pods) and letting Helm recreate it. The PVC has no
  `ownerReferences` and survives that untouched.
- The claim is still named `server-volume-victoria-metrics-server-0` **on purpose**. The kopia
  source identity is `<namespace>-<KOPIUR_APP>@<namespace>:/pvc/<KOPIUR_APP>`, so renaming
  `KOPIUR_APP` would start a fresh snapshot lineage and orphan the existing dailies in R2 with
  nothing to prune them.

## Backup staleness alerting is per-policy

The kopiur chart ships one flat `monitoring.prometheusRule.backupStaleAfterSeconds` applied to
every SnapshotPolicy. That cannot hold for a fleet with mixed schedules: set it for hourly
backups and the daily policy is "stale" for ~18h of every day; set it for the daily policy and
an hourly backup can be dead for a full day before anyone hears about it.

Until 2026-08-18 it was 6h, so `KopiurBackupStale` fired against `vm-single` (deliberately
`H 3 * * *`) daily and permanently. `apoci-data` (`H */6 * * *`) was one jitter away from the
same thing. That is worse than useless — a permanently-firing alert is exactly what stops
anyone noticing a real backup failure.

Two layers now:

1. **The chart's `KopiurBackupStale`, widened to 26h** (`backupStaleAfterSeconds: 93600`) — set
   to the loosest schedule in the fleet so it never false-fires. It stays enabled as a backstop:
   it still catches a genuinely dead backup even if layer 2 is removed, and its second branch
   (policy failing and never having succeeded) is independent of the threshold.
2. **`KopiurPolicyBackupStale` in the `baseline` VMRule** (`kopiur-overrides.rules`) — the real
   detector, with a per-policy allowance of roughly one interval plus grace:

   | Policy | Schedule | Allowance |
   | --- | --- | --- |
   | `gotosocial`, `continuwuity`, `towonel` | hourly | 6h (default) |
   | `apoci-data` | `H */6 * * *` | 8h (28800s) |
   | `server-volume-victoria-metrics-server-0` | `H 3 * * *` | 26h (93600s) |

   Only the two exceptions appear as `or` branches in the rule; `towonel` and the hourly policies
   fall through to the 21600s catch-all, which is correct and needs no edit. Verified against the
   live `baseline` VMRule 2026-08-21 — the expression carries exactly those two `policy=` selectors.

The threshold is built by `or`-chaining constant vectors off the metric itself, so the label
sets match and the comparison joins cleanly:

```promql
(kopiur_policy_last_backup_success_timestamp_seconds{policy="<exception>"} * 0 + <seconds>)
or
(kopiur_policy_last_backup_success_timestamp_seconds * 0 + 21600)
```

Each exception is one `or` branch ahead of the catch-all; anything unlisted defaults to 6h.
**When you change a `KOPIUR_SCHEDULE`, add or update its branch here** — nothing derives this
automatically, because kopiur exposes no metric carrying a policy's schedule or expected
interval (checked against the full `/metrics` surface on 2026-08-18).

The chart rule is left enabled rather than replaced because it carries ten other alerts
(`KopiurRepositoryNotReady`, `KopiurSnapshotFailed`, `KopiurRestoreFailed`, leader-election
health, and so on). Vendoring a copy to edit one expression would fork all of them and drift on
every Renovate chart bump.


## Gotcha: stale CSINode topology keys block every new PVC

`zfs.csi.openebs.io` has `storageCapacity: true`, so the scheduler will not place a
pod with an **unbound** PVC unless a matching `CSIStorageCapacity` object exists.

The zfs-localpv node plugin registers the node's labels as CSINode `topologyKeys` at
startup. tuppr sets `tuppr.home-operations.com/upgrading` on the node during an
upgrade — if the node reboots while that label is present, the key is baked into
CSINode. tuppr then removes the label, the capacity controller can no longer build a
complete topology segment, and it publishes nothing:

```text
Initial number of topology segments 0, storage classes 1, potential CSIStorageCapacity objects 0
```

The symptom is a pod stuck `Pending` with **"1 node(s) did not have enough free
storage"** while the pool is nearly empty, and `kubectl get csistoragecapacity -A`
returning nothing. Already-bound PVCs are unaffected, which is why it can sit
unnoticed until the next new app.

```bash
kubectl -n openebs-system rollout restart ds/zfs-localpv-node        # re-register CSINode
kubectl -n openebs-system rollout restart deploy/zfs-localpv-controller
kubectl get csistoragecapacities.storage.k8s.io -A                   # expect >= 1
```

Diagnose by diffing CSINode's `topologyKeys` against the node's actual labels — any
key with no matching label is the culprit.

## Migrating a PVC between StorageClasses

Recovered 2026-08-21 from a completed `local-path` → `openebs-zfs` migration (originally written
up as a skill, misfiled in Artemis, retired once the migration finished). The general restore
mechanics are above — § Restore, § `WaitForFirstConsumer` means a restore needs a consumer, and
§ Always retain the old volume first all apply unchanged. Only the migration-specific traps are
recorded here.

### `target.pvcRef`, never `target.pvc`

`Restore.spec.target` is a one-of: `populator`, `pvc`, or `pvcRef` (confirmed against the live
CRD — `kubectl explain restore.spec.target`). The component uses `populator: {}`; a manual
migration uses `pvcRef`.

`pvcRef` takes `{name, namespace}` and **points at a PVC you pre-created** — the Restore writes
into it and does not take ownership. `target.pvc` takes `{name, capacity, storageClassName,
accessModes}` — it makes the Restore **create and own** that PVC, so the claim carries an
ownerReference back to the Restore and is garbage-collected with it, and `openebs-zfs` being
`reclaimPolicy: Delete` then destroys the volume. This is the most destructive mistake available
in the procedure and it is a one-word difference.

### Annotate a Helm-managed PVC `helm.sh/resource-policy: keep` before switching to `existingClaim`

`helm.sh/resource-policy: keep` tells Helm to **skip deletion** of a resource it owns when that
resource leaves the release's manifest. Without it, the upgrade that switches to `existingClaim`
removes the chart-owned PVC from the release, and Helm deletes it — taking the volume you just
migrated into with it, because `openebs-zfs` is `reclaimPolicy: Delete`. Annotate first, then
switch the HelmRelease.

The annotation only stops the delete. It does **not** stop the chart minting its own claim if
`existingClaim` is ever unset again, and a kept PVC is thereafter unmanaged — Helm will not update
or remove it, so cleaning it up is a manual step you have to remember.

### A Postgres data dir (uid 999, mode 700) cannot be read by a kopiur mover

Neither `copyMethod: Direct` nor an unprivileged mover can read it. Copy it with a privileged
Job instead — `securityContext.runAsUser: 0`, busybox, `sh -c 'cp -a /source/. /dest/'`, mounting
the old PVC at `/source` and the new one at `/dest`.

Because that Job needs the destination under a temporary name, finish by **re-pointing the PV**
rather than copying twice: scale to 0, delete the temp PVC, strip the PV's `claimRef`
(`[{"op": "remove", "path": "/spec/claimRef"}]`), then recreate the PVC under the final name with
an explicit `volumeName`.

### Do not resume the Kustomization until the Restore completes

The mover holds the PVC `ReadWriteOnce`. Starting the app while the mover has it mounted
deadlocks both rather than producing a clear error.

### Not every PVC is backed up, and nothing warns you

kopiur only protects a PVC that has a `SnapshotPolicy`. Live coverage 2026-08-21 — 8 PVCs, 5
policies:

| PVC | Protected by |
| --- | --- |
| `fediverse/gotosocial`, `fediverse/apoci-data`, `matrix/continuwuity`, `observability/server-volume-victoria-metrics-server-0`, `towonel/towonel` | kopiur → R2 |
| `database/postgres-1` | **not kopiur** — barman WAL + base backups to `s3://frostlink-kopiur/barman/` |
| `observability/alertmanager`, `observability/gatus-sidecar` | **nothing** — accepted as reconstructible state |

`postgres-1` is deliberately not kopiur-backed: a filesystem snapshot of a running Postgres data
directory is not a consistent backup, and barman already produces one. Do not "fix" the gap by
adding a kopiur policy to it. The two `observability` claims are silence buffers and gatus history —
losing them costs alert-suppression state and a graph, not data. Anything added to that row later
needs a deliberate decision, because `KopiurPolicyBackupStale` can only alert on policies that
exist; an unbacked PVC is invisible to every alert in this file.

`ClusterRepository/r2` sets `deletionProtection.threshold: 10` — kopiur refuses a prune that would
delete more than 10 snapshots in one pass. That is a guard against a retention edit that
accidentally collapses history; if a legitimate retention tightening trips it, raise the threshold
for that change rather than deleting snapshots by hand.

### Two failure modes seen during the migration

- **Snapshot fails `disk quota exceeded`** — the `SnapshotPolicy` is missing
  `mover.cache.capacity` (2Gi sufficed). Set it before snapshotting.
- **Snapshot deletion hangs** — remove the `kopiur.home-operations.com/snapshot-cleanup`
  finalizer by hand if the cleanup Job never starts.

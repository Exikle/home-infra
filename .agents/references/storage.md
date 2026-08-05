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
- **PVC annotation `kustomize.toolkit.fluxcd.io/ssa: ignore`** — prevents Flux from overwriting the PVC after initial creation (critical for Restore-seeded PVCs).
- **Restore PVC on first deploy** — the PVC uses `dataSourceRef` pointing to the `Restore` CRD; Kopiur populates it from R2 on first apply. `onMissingSnapshot: Continue` means a missing snapshot doesn't block PVC creation.

## Restore

To restore from backup, the Kopiur component's `restore.yaml` handles it automatically on first deploy via `dataSourceRef`. For a manual re-restore, delete the PVC and let Flux re-apply the component.

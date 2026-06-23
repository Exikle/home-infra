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

- Hourly snapshots (`H * * * *` with 2m jitter)
- Retention: 24 hourly, 7 daily
- `copyMethod: Snapshot` — uses ZFS snapshots, not full copies

### Known quirks

- **`inheritSecurityContextFrom: pvcConsumer: {}`** is required in `SnapshotPolicy` — the mover must inherit the UID from the consuming app pod, or it gets permission errors writing to the volume. The component template already includes this.
- **Mover cache must be ≥ 2Gi** — the Kopiur default of 1Mi causes "disk quota exceeded" failures. The component template defaults to 2Gi; only override if you need more.
- **PVC annotation `kustomize.toolkit.fluxcd.io/ssa: ignore`** — prevents Flux from overwriting the PVC after initial creation (critical for Restore-seeded PVCs).
- **Restore PVC on first deploy** — the PVC uses `dataSourceRef` pointing to the `Restore` CRD; Kopiur populates it from R2 on first apply. `onMissingSnapshot: Continue` means a missing snapshot doesn't block PVC creation.

## Restore

To restore from backup, the Kopiur component's `restore.yaml` handles it automatically on first deploy via `dataSourceRef`. For a manual re-restore, delete the PVC and let Flux re-apply the component.

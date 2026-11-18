# Reference: kopiur — home-infra

This file covers backups. It covers the kopiur operator, `ClusterRepository/atlas` on NFS, the
component defaults, the mover uid, the cache budgets, how restores behave, and the conditions that
look broken but are not. It covers backup and restore only. The StorageClass and
VolumeSnapshotClass that the movers use are in `storage.md`.

Frostlink runs the same operator against a metered R2 bucket. Its doc is `openebs-zfs.md`
§ Backups via Kopiur. § Where this differs from Artemis in that file lists the deliberate
differences: the retention, the substitute var, and `usernameExpr`. Do not "align" the two
clusters by copying the setting of one onto the other.

## kopiur

VolSync is gone. `AGENTS.md` § "What was deliberately removed" is the home for that fact, and it
wins. Every backed-up app uses kopiur against `ClusterRepository/atlas` (NFS
`10.10.99.100:/mnt/atlas/Kopiur`). `grep -rln 'components/kopiur/backup' kube/clusters/artemis/apps/` lists
them. The old VolSync kopia repo stays on the NAS at `atlas/VolsyncKopia` as a frozen historical
fallback. To restore from it, you need a manual kopia client.

These are the component defaults (`kube/clusters/artemis/components/kopiur/backup/`). No manifest
states them in one place:

| Setting        | Default                                                | Override var                                              |
| -------------- | ------------------------------------------------------ | --------------------------------------------------------- |
| Schedule       | `H * * * *` (hourly)                                   | None. Edit the component or the app's `SnapshotSchedule`. |
| Retention      | 5 latest / 24 hourly / 30 daily / 8 weekly / 6 monthly | None. Edit the component.                                 |
| `copyMethod`   | `Snapshot` (VolumeSnapshot clone)                      | None                                                      |
| Compression    | `zstd`                                                 | None                                                      |
| PVC capacity   | `5Gi`                                                  | `KOPIUR_CAPACITY`                                         |
| StorageClass   | `miroir`                                               | `KOPIUR_STORAGECLASS` (app PVC only)                      |
| Staging class  | `miroir-local`                                         | `KOPIUR_STAGING_STORAGECLASS`                             |
| Snapshot class | `miroir`                                               | `KOPIUR_SNAPSHOTCLASS`                                    |
| Mover uid/gid  | `1000` / `1000`                                        | `KOPIUR_PUID` / `KOPIUR_PGID`                             |
| Access modes   | `ReadWriteOnce`                                        | `KOPIUR_ACCESSMODES`                                      |

The retention here is deeper than the retention of Frostlink on purpose. Frostlink keeps less,
because R2 is metered (`openebs-zfs.md` § Schedule and retention).

The substitute var is `${APP}`, not `${KOPIUR_APP}`. The component of Frostlink uses
`${KOPIUR_APP}`. The component of Artemis uses `${APP}`. `components/postgres/app` now also uses
`${APP}` as its default (`${PG_APP:=${APP}}`). Set `PG_APP` only when the database name differs.
If you copy a `postBuild.substitute` block between the two repos, a var silently stays
unsubstituted.

The kopia source identity is `<policy>@<namespace>:/pvc/<pvc>`. The `identityDefaults` on
`ClusterRepository/atlas` are `usernameExpr: policyName` and `hostnameExpr: namespace`. The
`usernameExpr` of Frostlink is `namespace + '-' + policyName`. So identities are not portable
between the two repositories. If you rename a policy, kopia starts a new snapshot lineage. The old
lineage becomes an orphan, and nothing prunes it.

### Retiring an app does not purge its backups

If you delete the Flux Kustomization of an app, the kopia lineage of the app becomes an orphan.
The lineage is not deleted. Pruning the `SnapshotPolicy` or `SnapshotSchedule` does cascade to the
child `Snapshot` CRs through ownerReference GC. They vanish from `kubectl get`, and it looks done.
It is not done. The controller runs that cascade as `plan=RetainSnapshotOnScheduleDelete` or
`RetainSnapshotOnPolicyDelete` (`mode=Retain`). The snapshots stay in the repository, with no
policy left to prune them.

To purge, delete the `Snapshot` CRs explicitly. Do this before you delete the Kustomization:

```bash
kubectl delete snapshots.kopiur.home-operations.com -n <ns> -l kopiur.home-operations.com/config=<app>
```

That path honours `spec.deletionPolicy: Delete` and the
`kopiur.home-operations.com/snapshot-cleanup` finalizer. The finalizer queues the repo-side
`SnapshotDeleteBatch` job. The `MassDeletionHeld` breaker on `ClusterRepository/atlas` trips above
10 pending external destructive deletions. So you must delete a long lineage in batches.

If a `Snapshot` CR stays in deletion, run
`mise run --yes //kube/clusters/artemis:release-snapshot <ns> <snapshot>`. It removes the
finalizer. The data of that snapshot stays in the repository.

The order is the whole trick, and you cannot recover from a wrong order. After the CRs are gone,
you cannot re-attach the snapshots. The `Snapshot` CRD builds a new snapshot from a PVC source. It
has no adopt or import field. The only remaining route is a manual kopia client against the
repository. The team learned this when it retired `home-automation/node-red` on 2026-09-08. It left
the 56 snapshots of that app behind on purpose, rather than purge them by hand.

`status.storageStats.snapshotCount` on the ClusterRepository is not a way to make sure that any of
this worked. `status.catalog.lastRefreshAt` lags by up to `catalog.refreshInterval` (1h), so the
number stays stale for an hour. Read the `kopiur-controller` logs instead.

- Reference the component in the `ks.yaml` components: `../../../../components/kopiur/backup`
- Set the PVC size in the `ks.yaml` postBuild substitute `KOPIUR_CAPACITY`, not in the app
  manifests.
- Each backed-up namespace also needs `../../components/kopiur/secret` in its namespace
  kustomization. The mover reads the repo password from its own namespace (`envFrom` is
  namespace-local). So the Secret name is fixed and cannot be per-app.
- In the HelmRelease, the PVC is `existingClaim: <app>`.
- Mover uid: it defaults to 1000. Override it with `KOPIUR_PUID` and `KOPIUR_PGID` only when
  something else owns the on-disk data of the app. Read the actual ownership. Never trust the
  `fsGroup` of the pod, because it misleads. apoci reported 999, but its data was 1000. pocket-id
  reported 65534, but its data was 1000. With `copyMethod: Snapshot`, the source clone is mounted
  read-only, so the kubelet cannot chgrp it. A mismatched mover gets permission denied. The
  `fsGroup` of the mover also owns the cache PVC, and the mover must be able to write to it. To
  list the apps that override the uid, run `grep -rn KOPIUR_PUID kube/clusters/artemis/apps/`.
  `cortex/hermes` sets 10000. Its image runs non-root only as that uid, and its data was re-owned
  to match (`hermes.md` § Run as uid 10000).
- `kopiur-system` pulls in `components/kopiur/secret` too. The operator reads the repository
  password to connect, and maintenance movers run in that namespace.
  `kopiur-system/kopiur/repository/kustomization.yaml` pulls it in, not the namespace
  kustomization. That way, `mise run //kube/clusters/artemis:apply-ks` can still test it.
- `restore.yaml` must mirror the mover identity of the SnapshotPolicy. If it does not, a restore
  writes files as 1000 whatever the uid of the app is, and the app cannot open its own data.
- A `Restore` is one-shot and terminal by design. Upstream says: _"a Restore is one-shot — fix the
  cause and create a new Restore"_. If you edit a completed one, it sits at
  `generation != observedGeneration` forever. kstatus then reports InProgress, and any
  `wait: true` Kustomization hangs for the full timeout in every cycle.
- The interface is delete-and-recreate, not edit. When the rendered spec of a Restore changes
  (`KOPIUR_PUID`/`KOPIUR_PGID`, storageclass, anything), delete the CR and let Flux recreate it.
  If you recreate a populator Restore over a bound PVC, nothing happens. This is documented. The
  Restore completes as `Ready=True reason=TargetAlreadyBound` with no mover run, and the live
  volume does not change. The CR has no finalizers and no ownerReferences, so deleting one cannot
  cascade.
- Do not recreate a Restore to pick up a newer snapshot on a bound PVC. It does not work. A
  populator gives a volume only to an _unbound_ claim. The source snapshot is pinned to
  `status.resolved` at first resolution. To re-restore, delete the PVC (keep its `dataSourceRef`)
  and let it be re-created. To re-resolve to a newer snapshot, delete and re-create the `Restore`.
- `restore.yaml` carries no `kustomize.toolkit.fluxcd.io/ssa: ignore`. Do not re-add it. Flux
  skips such objects entirely, so Flux never creates a Restore that carries it. `restore.yaml`
  keeps `mover.cache.mode: Ephemeral` and the mover identity block. Every app that overrides the
  uid depends on that block.
- `mise run //kube/clusters/artemis:apply-ks` overwrites a hand-created `Restore` with the rendered
  one. For any cross-policy restore (a rename, or recovering the data of one app into another app),
  set `onMissingSnapshot: Fail`. Then a bad source resolution fails loudly. It does not silently
  bind an empty volume. The default is `Continue`. Create both the `Restore` and the PVC by hand.
  Do not let `apply-ks` create the PVC.

### The kopia web UI is deliberately removed (2026-08-09)

`ClusterRepository/atlas` no longer sets `spec.server`. The standalone `httproute.yaml` for
`kopiur.dcunha.io` is deleted. Do not re-add it as a "missing" route. The operator creates the
Service from `spec.server`, so the route exists only when the UI does.

The user asked for the removal, because almost nobody used the UI. The server pod also holds the
repository decryption key, even in `readOnly: true` mode.

To inspect the repository without the UI, use `kopiur status -n <ns>` and `kopiur doctor -n <ns>`.

### Mover cache budgets — `contentCacheSizeMb` / `metadataCacheSizeMb` are mandatory

Set them on `ClusterRepository/atlas`. If they are not set, the maintenance mover fills its cache
PVC, and every run fails with `no space left on device`.

The kopia defaults are 5000 MB content plus 5000 MB metadata. So a 5Gi cache PVC cannot hold even
the content cache alone. These sizes were observed on the full 5Gi `kopiur-cache-atlas`:

- `cache/contents`: 4.0G
- `logs/`: 359M. Of that, `content-logs` is 346M. It is also unbounded, and kopiur has no
  configuration for log retention.
- `cache/metadata`: 295M
- `cache/index-blobs`: 170M

The connect then fails when it writes `repository.config`, and the error that surfaces is
misleading. `Cannot determine current user: user: Current requires cgo or $USER set in environment`
appears _above_ the real cause in the mover log. Read past it to the `no space left on device`
lines.

The budgets must leave headroom for logs on top of the two caches:

| Scope                     | mode         | capacity        | content | metadata | headroom |
| ------------------------- | ------------ | --------------- | ------- | -------- | -------- |
| `moverDefaults.cache`     | `Ephemeral`  | none (emptyDir) | 2000 MB | 1000 MB  | node     |
| `maintenance.mover.cache` | `Persistent` | 10Gi            | 3000 MB | 4000 MB  | ~3.5Gi   |

The per-app mover cache is an `emptyDir`, not a PVC (2026-09-07). An `Ephemeral` cache with no
`capacity` is a node-local `emptyDir`. `capacity` is the only thing that makes kopiur provision a
claim. So the `SnapshotPolicy` in the component has no `mover.cache` block. It inherits
`moverDefaults`: the mode, the budgets, and no capacity. This stops one `miroir-local` volume per
run across every hourly policy. `restore.yaml` keeps only `mover.cache.mode: Ephemeral`, with no
capacity.

A per-recipe `mover.cache` silently defeats the repository default. `MoverSpec` overlays
`MoverDefaults` field by field, and the recipe wins. The team once removed `capacity` from
`moverDefaults` alone. Nothing changed, because the component still set `capacity: 5Gi`, and the
cache PVCs kept being created. Change both, or change the component.

`storageClassName` on a cache with no `capacity` has no effect, because there is no PVC to place.
For that reason, the component has no cache storage-class variable.

Maintenance gets its own larger override. Full maintenance compacts index blobs and is bound by
metadata. It is the only kopiur cache that survives between runs, so it is the only cache that can
fill.

An ephemeral cache is regenerable, and kopiur discards it every run anyway. It is equally safe to
clear the persistent maintenance cache. Delete `kopiur-system/kopiur-cache-atlas` and let kopiur
recreate it.

### Mover placement is the scheduler's job, not kopiur's (2026-09-07)

`miroir-local` is `replicas: 1` on the `nvme` pool. That pool exists only on the three control
planes. Nothing told the scheduler this. Before the fix, the scheduler placed a mover on a worker.
miroir then placed the staged PVC elsewhere in the pool. The pod never bound, because the node
affinity of a PV is immutable. The team saw this on `matter-server-20260907054400`. Both PVCs were
annotated `selected-node: talos-w-01`, with the PVs on `talos-cp-03` and `talos-cp-01`.

The fix is `storageCapacity.enabled: true` on the miroir chart, not a kopiur nodeSelector. When the
chart publishes `CSIStorageCapacity`, the scheduler treats a `(node, class)` pair with no capacity
as unfit. `miroir-local` shows 0 on the workers and a non-zero capacity on the three storage nodes
(`kubectl get csistoragecapacities -n miroir-system -o custom-columns=CLASS:.storageClassName,CAPACITY:.capacity,NODE:.nodeTopology.matchLabels`).
`miroir` (replicated, remotely consumable) stays available everywhere. The fix
constrains only the pods that actually claim from such a class.

The team tried `moverDefaults.nodeSelector` first and reverted it, for three reasons:

- It applies to the whole repository.
- `SnapshotPolicy.spec.mover` has no scheduling fields to override it per app.
- It also pins a `copyMethod: Direct` mover away from the workload that the mover must run beside.

Cost: after an agent restart, a `WaitForFirstConsumer` pod waits up to `agent.poolStatsInterval`
(60s) for fresh capacity stats before it can schedule.

### `copyMethod: Direct` was evaluated and rejected

Direct mounts the live PVC, with no VolumeSnapshot and no staged PVC. Do not propose it again.

- The churn that it removes is cheap. A `replicas: 1` miroir volume has no DRBD layer. It is a
  plain lvmthin volume, and staging already moved to `miroir-local`.
- Direct is a crash-consistent live read. It reads a database file and its `-wal` moments apart.
  Many backed-up PVCs hold a database, and several are in WAL mode (`komga`, `hermes`, `frigate`,
  `qbittorrent`, `seerr`, `rensaio`). A connection to Postgres does not mean that the
  PVC has no secondary database.
- Scanning trap: `find -printf` is GNU-only, and busybox exits silently, which reads as clean.
  `find / -xdev` never enters a PVC. Derive the mountPath from the pod spec and scan that path.

### `IndexBlobHealth: False` is a warning about index size, not a broken repository

The repository sets `spec.health.indexBlobWarnThreshold: 4000` (the default is 1000). This keeps
`IndexBlobHealth` at `Healthy`. If it flips to `False / TooManyIndexBlobs` while `Ready=True`,
backups are not failing. Read `SnapshotPolicy.status.lastSuccessfulSnapshot`. That is the signal
that matters.

Mechanism: kopia compacts index blobs only two epochs behind the current one. An epoch cannot close
before `spec.parameters.epoch.minDuration` (`6h` here, and the kopia default is 24h). If the count
really climbs, do these steps in order:

1. Make sure that the maintenance Job runs.
2. If the Job is stuck on a stale lease owner, set `spec.maintenance.takeoverPolicy: Force` once.
3. Lower `epoch.minDuration` further.

Raising the threshold only silences the signal.

`toggle-kopiur` pauses the controller, not everything in kopiur. It leaves two things alone on
purpose:

- `kopiur-webhook`. Its Validating/MutatingWebhookConfiguration stays registered. If you scale the
  webhook to 0, every kopiur CR write fails.
- The `kopiur-repository` Kustomization. It keeps reconciling `ClusterRepository/atlas` on its own
  1h interval. Its `dependsOn: [kopiur]` is for apply order only, so suspending the parent does
  not suspend the child. It is harmless to reconcile that configuration while the controller is at
  0 replicas.

The mise tasks for snapshots and PVCs are in `tooling.md` § mise tasks, which wins. These are the
commands that it does not list:

```bash
mise run //kube/clusters/artemis:toggle-kopiur <suspend|resume>   # suspend/resume the controller (webhook stays up)
mise run --yes //kube/clusters/artemis:restore-pvc <ns> <app> [offset]  # in-place restore into a BOUND pvc; scales app to 0
kopiur status -n <ns>                      # repositories, policies, schedules
kopiur doctor -n <ns>                      # diagnose an installation
```

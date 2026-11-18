# Reference: Frostlink storage (OpenEBS ZFS)

## Storage Class

The default storage class is `openebs-zfs`. Its provisioner is `zfs.csi.openebs.io`.

- Pool: `openebs` (`poolname`), a ZFS pool on the separate block volume `sdb`, not on the boot
  disk (`oci-node.md` § The node)
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

`openebs-zfs` is the default class. If you accept the default, you can leave out
`storageClassName`. It is the only class on Frostlink. There is no RWX class and no second tier.

### Where this differs from Artemis

Artemis documents kopiur in `kopiur.md` and `storage.md`. The kopiur semantics are the same on both
clusters. Two things differ:

- Populator restore. Both clusters bind `WaitForFirstConsumer`. So on both, a populator restore needs
  the workload scaled back up (`storage.md` § Binding mode decides how a restore is driven). The
  in-place `restore-pvc` flow on Artemis does the opposite: it scales to 0.
- How the pods reach the repository secret. Frostlink uses `credentialProjection` from
  `kopiur-system`. Artemis uses a `kopiur/secret` component per namespace. The substitute variable
  is `${KOPIUR_APP}` here and `${APP}` on Artemis (§ Component template).

On Frostlink, deleting a volume also has two layers. A `ZFSVolume` CR in `openebs-system` stays
after you remove the PV. You must delete it separately (§ Always retain the old volume first).

## VolumeSnapshotClass

`zfs-snapshotclass` has the driver `zfs.csi.openebs.io` and the deletion policy `Delete`. Kopiur uses
it for snapshot-based backups.

## Backups via Kopiur

Kopiur runs in `kopiur-system`. It snapshots PVCs through ZFS and pushes them to Cloudflare R2
(`ClusterRepository: r2`).

### Component template

All stateful apps use the shared component at `kube/clusters/frostlink/components/kopiur/`. Add it
to `ks.yaml`:

```yaml
spec:
    components:
        - ../../../../components/kopiur
```

Then set `KOPIUR_APP` in `postBuild.substitute`. To see the other variables and their defaults, run
`grep -rn 'KOPIUR_' kube/clusters/frostlink/components/kopiur`. They cover capacity, storage class,
snapshot class, cache, schedule and retention. `KOPIUR_APP` names every Kopiur resource: PVC,
SnapshotPolicy, SnapshotSchedule and Restore.

The variable is `KOPIUR_APP`, not `APP`. Every resource in `components/kopiur/` interpolates
`${KOPIUR_APP}` with no default. If an app substitutes `APP` instead, the render keeps the literal
`${KOPIUR_APP}` in the names. The Kustomization then fails on the invalid resource name. The
equivalent component on Artemis uses plain `${APP}`. So if you copy a `postBuild.substitute` block
between the two clusters, exactly this one line is wrong.

The component creates 4 resources: `PersistentVolumeClaim`, `SnapshotPolicy`, `SnapshotSchedule`
and `Restore`.

Three behaviours the component enables that nothing else documents:

- `credentialProjection.enabled: true` is set on both the `SnapshotPolicy` and the `Restore`.
  `credentialProjection.allowed: true` on `ClusterRepository/r2` matches it. The repository Secret
  lives in `kopiur-system`. Projection lets a mover in `fediverse` or `matrix` read that Secret. No
  namespace needs its own copy. If you disable projection on Frostlink, every backed-up namespace
  needs its own copy of the R2 secret.
- A `preflight` check named `backend-reachable` (`expr: repository.backendReachable`,
  `timeout: 30m`). It holds back the mover only when the health probe positively observed that R2
  is unreachable. `backendReachable` is true when the probe is disabled or has no evidence. So the
  check fails open. Its purpose is to hold a backup during a short R2 outage, rather than mark the
  backup `Failed`. That is why the timeout is long.
- Weekly quick verification: `verification.quick.schedule: H 4 * * 0`, jitter 30m. The time zone
  comes from the `scheduleDefaults` of the repository. This is a verification at the blob level,
  not a restore drill. It shows in the `LAST-VERIFIED` column of
  `kubectl get snapshotpolicy -A --context frostlink`. If `LAST-VERIFIED` is older than about 8
  days, verification is not running, even if backups are.
- Monthly deep verify: the optional `kube/clusters/frostlink/components/kopiur-deep-verify` layer
  (`H 5 1 * *`, jitter 1h). It uses a scratch PVC sized by `KOPIUR_DEEP_VERIFY_CAPACITY`, default
  `5Gi`. Deep verify is a real restore into scratch space. So it is the only check that proves the
  data comes back. It is also the only check that costs CPU and disk. `fediverse/gotosocial` and
  `network/headscale` use it.

### Schedule and retention

The component defaults are:

- Hourly snapshots (`H * * * *`, 2m jitter).
- Retention: 3 latest, 24 hourly, 7 daily, 4 weekly, 3 monthly.
- `copyMethod: Snapshot`. This takes ZFS snapshots, not full copies. `Direct` is wrong, because
  openebs-zfs cannot remount a live volume.

Artemis keeps a different, longer retention, because it writes to NFS and not to a metered R2
bucket. The two are different on purpose. Do not align them.

To list the fleet, run `kubectl get snapshotpolicy -A --context frostlink`. The Headscale policy
matters more than its size suggests. If its restore comes back empty, every device must register
again (`oci-rebuild.md`).

You can override the cadence and the retention per app in `postBuild.substitute`
(`KOPIUR_SCHEDULE`, `KOPIUR_KEEP_LATEST/HOURLY/DAILY/WEEKLY/MONTHLY`). The current overrides:

| App         | Schedule               | Why                                                                                                                                                                                                                         |
| ----------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vm-single` | `H 3 * * *`, 1/0/7/0/0 | The TSDB of VictoriaMetrics rewrites its parts all the time. Hourly snapshots deduplicated badly and caused most of the churn in the R2 repository. Metrics are the easiest data here to rebuild. Daily, 7 deep, is enough. |
| `apoci`     | `H */6 * * *`          | Registry blobs are content-addressed and in practice never change. Hourly gave almost nothing more than 6-hourly. Retention stays at the component default (about 30 restore points).                                       |

> If you change a `KOPIUR_SCHEDULE`, also update the branch of that policy in
> `KopiurPolicyBackupStale`. See "Backup staleness alerting is per-policy" below. Nothing derives it
> automatically. If you forget, the alert fires all the time and nobody reads it.

### The R2 credential key is unrecoverable if repointed — read before editing

`kube/clusters/frostlink/apps/kopiur-system/kopiur/repository/externalsecret.yaml` pulls
`KOPIA_PASSWORD` from the 1Password item `kopiur-frostlink`. The `-frostlink` suffix is
load-bearing. The item named only `kopiur` belongs to Artemis. If you point this key at the wrong
item, it syncs with no error. It fails only later, at connect time, with
`invalid repository password`.

A kopia repository does not store its password, and you cannot open it without the original
password. So a wrong value that looks valid here is unrecoverable. There is a second trap. An
ExternalSecret that is in error does not change its target Secret. So a broken ES is often the only
thing that keeps the live credential. "Fixing" the error is what destroys it.

Never repoint this key before you make sure that the new value actually opens the repository. This
went wrong once. Recovery worked only because the deleted item was still in the 1Password trash.

### barman WAL retention

The shared Postgres cluster archives WAL to the same bucket, under `barman/`
(`kube/clusters/frostlink/apps/database/postgres/cluster/objectstore.yaml`). The setting is
`retentionPolicy: 14d`. That gives enough PITR for a single-node homelab VPS. It also cuts both the
size of `barman/` and its object count roughly in half. WAL segments are most of the object count of
the bucket, but only a small part of its bytes. `data.compression` is `gzip`. The CRD enum is
`[bzip2, gzip, lz4, snappy]`, so zstd is not available for that field. It is available for
`wal.compression`, which uses it.

### Known quirks

- The two CRs get their mover UID from different places, and you cannot swap them.
  `SnapshotPolicy` uses `inheritSecurityContextFrom: pvcConsumer: {}`. It takes the UID from the pod
  that uses the PVC at that time. During a backup, that pod is the running app. `Restore` uses
  `inheritSecurityContextFrom: snapshot: {}`. It replays the UID and GID recorded on the backup
  snapshot, so it needs no live pod. That is the reason for the difference. During a restore, the
  PVC is often unbound, and no consumer exists to read a UID from. Both settings are already in the
  component template. `pvcConsumer` is for backup only. The webhook rejects it on a `Restore`.
  `workloadSelector` works on both, but you do not need it. Use it only when a snapshot is older
  than the change that started to record the UID. If you get this wrong, the restored tree is
  written as uid 1000, and the app cannot open its own data.
- `inheritSecurityContextFrom` sees only a UID that the pod spec pins. The field documentation of
  the CRD says this: a UID that comes from the `USER` line of the image is not in the pod spec, so
  it cannot be inherited. The mover then runs as the UID of its own image, with no warning. Set
  `securityContext` or `podSecurityContext` next to it. They override field by field, and they are
  the fallback when no workload pod resolves.
- Never leave the mover cache at the Kopiur default of 1Mi. It fails with "disk quota exceeded".
  The component template defaults to 2Gi. Apps with little data run well on 1Gi (towonel and
  headscale override `KOPIUR_CACHE_CAPACITY: 1Gi`). If a large app hits the quota error, size the
  cache up, not down.
- There is no `kustomize.toolkit.fluxcd.io/ssa` annotation on the PVC or the Restore. Flux applies
  them normally. A rendered PVC that matches the bound one is a no-op. `ssa: ignore` skips the
  apply completely. Flux then cannot create these resources on a fresh cluster, or recreate them
  for a restore. Do not add the annotation again. § No `ssa:` annotation gives the prerequisite that
  makes it safe to run with no annotation.
- Restore PVC on first deploy. The PVC uses `dataSourceRef` to point at the `Restore` CRD. Kopiur
  fills it from R2 when a pod claims it. `onMissingSnapshot: Continue` means that a missing
  snapshot does not stop PVC creation. That is exactly why a stale `Restore` CR can give back an
  empty volume and report success. See the Restore section.
- The populator acts only on an UNBOUND claim. After the PVC is bound, the Restore reports
  `Ready=True` with reason `TargetAlreadyBound` and does nothing. It makes no prime PVC, starts no
  mover, and does not touch the live volume. `fediverse/apoci-data` is in exactly this state. That
  behaviour is correct and safe. But it means that if you edit a `Restore` and wait, nothing is
  ever restored. You must delete the PVC so that it is created again unbound, with its
  `dataSourceRef`. `mise run //kube/clusters/frostlink:restore-pvc` is the sequence that does this
  safely.
- `ClusterRepository/r2` pins a few defaults on purpose:
    - `deletionProtection.threshold: 10` holds external Snapshot deletions until the
      `kopiur.home-operations.com/allow-mass-deletion` annotation acknowledges them. This is the
      CRD default, kept visible.
    - `health.probe.enabled` is off by default. It is on here, so a wiped or unreachable bucket
      shows up on its own and not at restore time.
    - `scheduleDefaults.timezone` reaches only the verification, replication and maintenance crons.
      `SnapshotSchedule` sets its own.
- `rbac.browseRole: true` in the kopiur HelmRelease adds the ClusterRole behind
  `kubectl kopiur ls/cat/download/browse`. It gives no access to Secrets. Bind that separately.

## Restore

Use `mise run --yes //kube/clusters/frostlink:restore-pvc <ns> <ks> <claim>`. To go back further,
add a snapshot offset as a 4th argument. The task contains every constraint below. Before it
reports success, it also makes sure that the restore actually came from a snapshot. Do not run the
sequence by hand.

Rough timing (measured 2026-08-18, single node to R2, apps of 0.4-3 GiB): about 1-2 minutes end to
end. About 16s of that is fixed overhead (prime PVC, Job scheduling, kopia connect). Workloads with
many small files are slower than their size suggests. Do not estimate the time from the bytes.

### The Restore CR pins its snapshot resolution at creation — permanently

The controller decides `Restore.status.resolved.pinnedAt` and `.resolution` once, when the CR is
created. It never evaluates them again. A `Restore` created on the first deploy of an app, before
any snapshot exists, pins `resolution: NoSnapshot` forever. The component sets
`policy.onMissingSnapshot: Continue`. So every later restore then does this:

- It provisions an empty volume.
- It runs no mover Job at all.
- It reports `phase: Completed`, `Ready: True`.

The app starts on the empty volume and initializes a fresh database. This is silent data loss that
looks like success. It happened on continuwuity, whose Restore stayed poisoned for 40 days.

Always delete and recreate the `Restore` CR before you restore. It then resolves again against the
current `SnapshotPolicy`. There are three states, not two. Read them like this:

| `status.resolved.resolution`   | Meaning                                                                                                                                      |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `Snapshot`                     | Healthy. It resolved against a real snapshot and will restore data.                                                                          |
| `NoSnapshot`                   | Poisoned. The volume is empty. Stop and use the retained PV.                                                                                 |
| _absent_, `TargetAlreadyBound` | Healthy. The PVC is already bound, so there was nothing to fill, and nothing is pinned. It resolves fresh when a restore is actually needed. |

The third row is what a repaired `Restore` looks like while its PVC is still bound. When you delete
and recreate the CR, the `NoSnapshot` pin goes away. The live PVC needs no filling, so the new CR
stays unpinned and does not resolve to `Snapshot`. Do not read the absent field as a failure. The
danger was never "no resolution". It was a resolution pinned to `NoSnapshot`.

You cannot see the pin in `phase`, which reads `Completed` in both cases. To audit the whole fleet,
run one command:

```bash
kubectl get restore -A --context frostlink -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
RESOLUTION:.status.resolved.resolution,PINNED:.status.resolved.pinnedAt,PHASE:.status.phase
```

To repair a `NoSnapshot` pin, delete the CR and let Flux recreate it. The PVC stays `Bound` and the
pod does not restart. The Kustomization interval is `1h`, so force a reconcile. Do not wait. Every
app onboarded through the kopiur component starts in this state, because the `Restore` is created
on first deploy, before any snapshot exists. So treat `NoSnapshot` as the default, not the
exception.

### No `ssa:` annotation — and why the old one was wrong

The PVC and the Restore of the component carry no `kustomize.toolkit.fluxcd.io/ssa` annotation. This
is the same as upstream. Flux applies them normally. A rendered PVC that is identical to the bound
one is a no-op apply. So nothing changes and nothing is rejected.

`ssa: ignore` makes kustomize-controller skip the resource completely. It logs
`"PersistentVolumeClaim/<ns>/<app>":"skipped"`. The results:

- Flux never creates these resources on a fresh cluster. It also never recreates them after you
  delete them for a restore. A Flux bootstrap from nothing leaves every Kopiur-backed app with no
  PVC.
- A change to `KOPIUR_CAPACITY` in git never reaches the cluster.

You can drop the annotation only after every live PVC already matches its rendered manifest.

> The prerequisite is real. `spec.dataSourceRef` cannot change after the PVC is bound. Flux applies
> a Kustomization atomically, so one rejected PVC blocks the _entire_ Kustomization. This failure is
> safe, because the app keeps running. But nothing else in that Kustomization reconciles either. If
> a PVC is older than the component and has no `dataSourceRef`, you must recreate it through
> `mise run //kube/clusters/frostlink:restore-pvc` before the annotation can come off. Before you
> touch this, test it with a server dry-run:
>
> ```
> mise run //kube/clusters/frostlink:render-ks <ns> <app> | kubectl apply --server-side \
>   --force-conflicts --field-manager=kustomize-controller --dry-run=server --context frostlink -f -
> ```

> It is not enough to remove the annotation from git. kustomize-controller reads the annotation off
> the live object, not only off the rendered manifest. So a resource that still carries a stale
> `ssa: ignore` is skipped forever. There is no warning, because the Kustomization still reports
> Ready. To strip it from the live objects, run a server-side apply that no longer includes the
> field. `mise run //kube/clusters/frostlink:apply-ks <ns> <app>` does exactly that. Then make sure
> that it worked:
>
> ```
> kubectl -n flux-system logs deploy/kustomize-controller --since=2m --context frostlink \
>   | grep -oE '"PersistentVolumeClaim/[^"]*":"[a-z]*"'
> ```
>
> `unchanged` or `configured` means that Flux manages it. `skipped` means that Flux still ignores it.

A bound PVC is now a no-op apply. So `mise run //kube/clusters/frostlink:apply-ks` works again on
Kopiur-backed apps. If a future app gets a PVC that the component did not create, the problem comes
back. The fix is always to recreate that PVC through the restore path. Never add the annotation
again.

### `WaitForFirstConsumer` means a restore needs a consumer

`openebs-zfs` is `volumeBindingMode: WaitForFirstConsumer`. A new PVC stays `Pending` with
`Used By: <none>`. The populator does nothing until a pod claims it. To drive the restore, you must
scale the workload back up. The restore cannot run with the app at zero. This is the opposite of
what you expect.

Side effect: the real app is the first consumer. So it starts to change the volume as soon as the
restore lands. To look at a restored volume before anything changes it, use a temporary consumer
pod (`mise run //kube/clusters/frostlink:browse-pvc`) as the first consumer instead of the app.

### Always retain the old volume first

Set the PV to `Retain` before you delete the PVC. The `mise run //kube/clusters/frostlink:restore-pvc`
task does this automatically. The reclaim policy of the storage class is `Delete`. Without
`Retain`, the old volume is destroyed as soon as the PVC goes away. The empty-restore failure above
then becomes unrecoverable. This step is the only reason the 2026-08-18 test did not lose data.

After you make sure that the restore is good, reclaim the retained volume. It is not enough to
remove the PV. The `ZFSVolume` CR in `openebs-system` (and its dataset) is orphaned separately. You
must remove it too, or the space stays leaked. The task prints the exact command when it finishes.

## Why vm-single uses `existingClaim`

`server.persistentVolume.existingClaim` binds the victoria-metrics-single chart to the PVC that the
kopiur component creates. Without it, the chart makes its own claim from a StatefulSet
`volumeClaimTemplate`.

A `volumeClaimTemplate` PVC cannot carry `spec.dataSourceRef`. So Kopiur backs up a claim made from
a template, but the populator can never restore it. The StatefulSet always recreates the claim from
its own template. When you set `existingClaim`, the chart drops `volumeClaimTemplates` completely
and emits a plain `volumes[]` reference. To make sure of this, run
`kubectl get sts victoria-metrics-server -n observability --context frostlink -o jsonpath='{.spec.volumeClaimTemplates}'`.
The output must be empty. Run it again after any major chart bump. The failure gives no error,
because a template that comes back quietly makes a second claim.

Two things to know before you change this:

- `volumeClaimTemplates` cannot change on a live StatefulSet. So the switch required deleting the
  StatefulSet (orphaning its pods) and letting Helm recreate it. The PVC has no `ownerReferences`,
  so it survived that untouched.
- The claim is still named `server-volume-victoria-metrics-server-0` on purpose. The kopia source
  identity is `<namespace>-<KOPIUR_APP>@<namespace>:/pvc/<KOPIUR_APP>`. If you rename `KOPIUR_APP`,
  a new snapshot lineage starts. The existing dailies in R2 are then orphaned, and nothing prunes
  them.

## Backup staleness alerting is per-policy

The kopiur chart ships one flat `monitoring.prometheusRule.backupStaleAfterSeconds`. It applies to
every SnapshotPolicy. One value cannot work for a fleet with mixed schedules. If you set it for
hourly backups, the daily policy is "stale" for about 18h of every day. If you set it for the daily
policy, an hourly backup can be dead for a full day before anyone hears about it.

At 6h, `KopiurBackupStale` fired against `vm-single` (`H 3 * * *` on purpose) every day, all the
time. That is worse than useless. An alert that fires all the time is exactly what stops anyone from
seeing a real backup failure.

There are now two layers:

1. The chart rule `KopiurBackupStale`, widened to 26h (`backupStaleAfterSeconds: 93600`). This is
   the loosest schedule in the fleet, so it never fires falsely. It stays enabled as a backstop. It
   still catches a backup that is really dead, even if layer 2 is removed. Its second branch (a
   policy that fails and never succeeded) does not depend on the threshold.
2. `KopiurPolicyBackupStale` in the `baseline` VMRule (`kopiur-overrides.rules`). This is the real
   detector. Each policy gets an allowance of about one interval plus a grace period:

    | Policy                                               | Schedule      | Allowance    |
    | ---------------------------------------------------- | ------------- | ------------ |
    | `gotosocial`, `continuwuity`, `headscale`, `towonel` | hourly        | 6h (default) |
    | `apoci-data`                                         | `H */6 * * *` | 8h (28800s)  |
    | `server-volume-victoria-metrics-server-0`            | `H 3 * * *`   | 26h (93600s) |

    Only the two exceptions are `or` branches in the rule. The hourly policies fall through to the
    21600s catch-all. That is correct and needs no edit.

The rule builds the threshold by `or`-chaining constant vectors off the metric itself. So the label
sets match, and the comparison joins cleanly:

```promql
(kopiur_policy_last_backup_success_timestamp_seconds{policy="<exception>"} * 0 + <seconds>)
or
(kopiur_policy_last_backup_success_timestamp_seconds * 0 + 21600)
```

Each exception is one `or` branch before the catch-all. Anything not listed defaults to 6h. When you
change a `KOPIUR_SCHEDULE`, add or update its branch here. Nothing derives this automatically,
because kopiur exposes no metric that carries the schedule or the expected interval of a policy.

The chart rule stays enabled and is not replaced, because it carries ten other alerts
(`KopiurRepositoryNotReady`, `KopiurSnapshotFailed`, `KopiurRestoreFailed`, leader-election health,
and others). A vendored copy made to edit one expression forks all of them. That copy then
drifts on every Renovate chart bump.

## Gotcha: stale CSINode topology keys block every new PVC

`zfs.csi.openebs.io` has `storageCapacity: true`. So the scheduler does not place a pod with an
unbound PVC unless a matching `CSIStorageCapacity` object exists.

At startup, the zfs-localpv node plugin registers the labels of the node as CSINode `topologyKeys`.
During an upgrade, tuppr sets `tuppr.home-operations.com/upgrading` on the node. If the node reboots
while that label is present, the key is fixed into CSINode. tuppr then removes the label. The
capacity controller can then no longer build a complete topology segment, and it publishes nothing:

```text
Initial number of topology segments 0, storage classes 1, potential CSIStorageCapacity objects 0
```

The symptom is a pod stuck `Pending` with "1 node(s) did not have enough free storage", while the
pool is nearly empty. `kubectl get csistoragecapacity -A --context frostlink` also returns nothing.
PVCs that are already bound are not affected. That is why the fault can stay unseen until the next
new app.

```bash
kubectl -n openebs-system rollout restart ds/zfs-localpv-node --context frostlink        # re-register CSINode
kubectl -n openebs-system rollout restart deploy/zfs-localpv-controller --context frostlink
kubectl get csistoragecapacities.storage.k8s.io -A --context frostlink                   # expect >= 1
```

To find the cause, compare the `topologyKeys` of CSINode with the actual labels of the node. A key
with no matching label is the cause.

## Migrating a PVC between StorageClasses

The general restore mechanics above apply with no change: § Restore, § `WaitForFirstConsumer` means
a restore needs a consumer, and § Always retain the old volume first. This section records only the
traps that are specific to a migration.

### `target.pvcRef`, never `target.pvc`

`Restore.spec.target` is a one-of (`kubectl explain restore.spec.target --context frostlink`). The
options are `populator`, `pvc`, `pvcRef` and `streamExec`. The component uses `populator: {}`. A
manual migration uses `pvcRef`.

`pvcRef` takes `{name, namespace}` and points at a PVC that you created first. The Restore writes
into it and does not take ownership. `target.pvc` takes `{name, capacity, storageClassName,
accessModes}`. It makes the Restore create and own that PVC. The claim then carries an
ownerReference back to the Restore, and garbage collection deletes it with the Restore. Because
`openebs-zfs` is `reclaimPolicy: Delete`, that destroys the volume. This is the most destructive
mistake in the procedure, and it is a one-word difference.

### Annotate a Helm-managed PVC `helm.sh/resource-policy: keep` before switching to `existingClaim`

`helm.sh/resource-policy: keep` tells Helm not to delete a resource that it owns when that resource
leaves the manifest of the release. Without it, the upgrade that switches to `existingClaim` removes
the PVC of the chart from the release, and Helm deletes it. The volume that you just migrated into
goes with it, because `openebs-zfs` is `reclaimPolicy: Delete`. Annotate first. Then switch the
HelmRelease.

The annotation only stops the delete. If `existingClaim` is ever unset again, the chart still makes
its own claim. A kept PVC is also unmanaged from then on. Helm does not update or remove it, so you
must remember to clean it up by hand.

### A Postgres data dir (uid 999, mode 700) cannot be read by a kopiur mover

Neither `copyMethod: Direct` nor an unprivileged mover can read it. Copy it with a privileged Job
instead: `securityContext.runAsUser: 0`, busybox, `sh -c 'cp -a /source/. /dest/'`. Mount the old
PVC at `/source` and the new one at `/dest`.

That Job needs the destination under a temporary name. So finish by pointing the PV at the final
name, and do not copy twice:

1. Scale to 0.
2. Delete the temporary PVC.
3. Remove the `claimRef` of the PV (`[{"op": "remove", "path": "/spec/claimRef"}]`).
4. Recreate the PVC under the final name with an explicit `volumeName`.

### Do not resume the Kustomization until the Restore completes

The mover holds the PVC `ReadWriteOnce`. If the app starts while the mover has the PVC mounted, both
deadlock. You get no clear error.

### Not every PVC is backed up, and nothing warns you

kopiur protects only a PVC that has a `SnapshotPolicy`. Compare
`kubectl get pvc -A --context frostlink` with `kubectl get snapshotpolicy -A --context frostlink`.
The gaps are on purpose:

- `database/postgres-*` is not backed up by kopiur. A filesystem snapshot of a running Postgres data
  directory is not a consistent backup. barman (WAL and base backups to
  `s3://frostlink-kopiur/barman/`) already makes one. Do not "fix" the gap with a kopiur policy.
- `observability/alertmanager` and `observability/gatus-sidecar` have no backup at all. They hold
  silence buffers and gatus history. If you lose them, you lose alert-suppression state and a graph,
  not data.

Anything added to that list needs a deliberate decision. `KopiurPolicyBackupStale` can alert only on
policies that exist. No alert in this file can see a PVC with no backup.

`ClusterRepository/r2` sets `deletionProtection.threshold: 10`. kopiur refuses a prune that deletes
more than 10 snapshots in one pass. This guards against a retention edit that collapses history by
accident. If a correct, tighter retention trips it, raise the threshold for that change. Do not
delete snapshots by hand.

### Two failure modes seen during the migration

- Snapshot fails with `disk quota exceeded`. The `SnapshotPolicy` has no `mover.cache.capacity`
  (2Gi was enough). Set it before you take the snapshot.
- Snapshot deletion hangs. If the cleanup Job never starts, remove the
  `kopiur.home-operations.com/snapshot-cleanup` finalizer by hand.

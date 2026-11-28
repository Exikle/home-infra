---
name: recreate-pvc
description: Delete and recreate an app's PVC so it comes back on current StorageClass parameters, restoring its data from kopiur on the way. Use for "recreate the PVC", "migrate a volume to the new storage class", "the PVC is on the old settings", "reprovision X's volume", or after a StorageClass parameter change that only takes effect on newly provisioned volumes. The volume's settings are the reason here. For plain data loss or corruption with the PVC otherwise fine, use `kopiur-restore` instead. Scoped to the Artemis cluster.
compatibility: Destroys and reprovisions a live PVC. Requires a verified kopiur snapshot first, and the `I_HAVE_A_KOPIUR_SNAPSHOT` marker to pass the destructive-command guard.
---

# Skill: Recreate a PVC (and restore it from kopiur)

Delete the PVC of an app and let the cluster create it again. The new volume then gets the current
StorageClass parameters. The data comes back through the kopiur volume populator.

> Read `.agents/references/kopiur.md` and `.agents/references/storage.md` first.

StorageClass parameters are set when the volume is provisioned. A change to the class does nothing
to existing volumes. The only way that they get the change is a new PVC.

A kopiur-backed app runs as a StatefulSet. Its PVC comes from a `volumeClaimTemplates` entry and is
named `<claim>-<app>-0`. The claim is `config` by default, or `data` when the Kustomization sets
`KOPIUR_CLAIM: data` (`kopiur.md` § Backing up an app). This skill uses `<pvc>` for that name.

Pass `--context artemis` to every `kubectl` and `flux` command below. Run every `mise run` task
from your worktree.

## Step 0: Make sure that a restore path exists

When you delete a PVC, you destroy the volume. `miroir` has `reclaimPolicy: Delete`, so the old PV
is gone when the PVC is gone. You cannot undo this.

```bash
kubectl get pvc -n <ns> <pvc> -o jsonpath='{.spec.dataSourceRef.kind}/{.spec.dataSourceRef.name}{"\n"}' --context artemis
```

- `Restore/<app>`: the kopiur populator restores the volume. Continue.
- Empty: there is no restore path. If you delete the PVC, the data is lost for good. Continue only
  for a cache that rebuilds itself, or when the user accepts the loss.

## Step 1: Suspend Flux

Suspend the root Kustomization and the Kustomization of the app, in two calls (`AGENTS.md`
rule 1). Otherwise a reconcile in the middle of these steps undoes them.

```bash
mise run //kube/clusters/artemis:suspend-ks flux-system flux-system
mise run //kube/clusters/artemis:suspend-ks <ns> <ks>
```

If an operator owns the workload instead of a chart, scale the operator to 0 first. A suspended
Kustomization does not stop an operator from scaling the app back up. To find the owner, run
`kubectl get sts -n <ns> <app> -o jsonpath='{.metadata.ownerReferences}' --context artemis`.

## Step 2: Stop the app

Note the replica count. You need it in Step 5:
`kubectl get sts -n <ns> <app> -o jsonpath='{.spec.replicas}' --context artemis`.

If the app has a zeroscaler HPA, delete the HPA first, or it scales the app up again:
`kubectl delete hpa <app> -n <ns> --context artemis`. Step 5 creates it again.

The guard blocks `kubectl scale` (rule `kubectl-mutation`). Use the `scale-workload` task. It asks
for confirmation, so it needs `--yes`:

```bash
mise run --yes //kube/clusters/artemis:scale-workload <ns> sts/<app> 0
```

Wait until no pod uses the volume. This command must return nothing:

```bash
kubectl get pods -n <ns> --context artemis -o jsonpath="{range .items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=='<pvc>')]}{.metadata.name}{'\n'}{end}"
```

A pod stuck in `Terminating` holds the volume. Force it:
`kubectl delete pod -n <ns> <pod> --force --grace-period=0 --context artemis`.

## Step 3: Take a fresh snapshot

The app is stopped, so a snapshot now holds all of its data.

```bash
mise run //kube/clusters/artemis:snapshot-pvc <ns> <app>
kubectl get snapshot -n <ns> <snapshot> -o jsonpath='{.status.phase} {.status.stats.sizeBytes} {.status.resolved.sources[0].pvc}{"\n"}' --context artemis
```

Wait until the phase is `Succeeded`. Make sure that the size is plausible and that the source is
`<ns>/<pvc>`. The populator has `policy.onMissingSnapshot: Continue`. A missing snapshot gives a
silently empty volume, not an error.

## Step 4: Delete the PVC and the Restore

`guard-destructive.sh` blocks `kubectl delete ... pvc`. For a planned recreation with a verified
snapshot, turn off that one rule with the marker. The marker must start the command, as an
environment assignment. A trailing comment does not work:

```bash
I_HAVE_A_KOPIUR_SNAPSHOT=1 kubectl delete pvc -n <ns> <pvc> --wait=false --context artemis
```

A command that starts with `VAR=` matches no allow-list entry, so the user approves it. The marker
turns off only `kubectl-delete-critical`. Every other rule still applies. Do not use the marker
unless you did Step 3.

Wait until the PVC is gone. See the `Terminating` gotcha below.

Then delete the Restore. A `Completed` Restore stays pinned to the snapshot that it resolved
first, so the new claim would get old data:

```bash
kubectl delete restore -n <ns> <app> --context artemis
```

## Step 5: Create the Restore again and start the app

Apply the Kustomization of the app. It creates a fresh Restore, which resolves offset 0 to the
snapshot from Step 3:

```bash
mise run //kube/clusters/artemis:apply-ks <ns> <ks>
mise run --yes //kube/clusters/artemis:scale-workload <ns> sts/<app> 1
```

Use the replica count from Step 2 if it was not 1. The StatefulSet creates
`<pvc>` from its template, and the populator fills it.

## Step 6: Watch the restore

A large restore takes minutes. A 5.5 GB volume took about 8 minutes. To see progress, read the log
of the mover:

```bash
kubectl get restore -n <ns> <app> -o jsonpath='{.status.claims.<pvc>.phase} {.status.claims.<pvc>.job}{"\n"}' --context artemis
kubectl logs -n <ns> job/<job> -c mover --context artemis --tail=3
```

If the last line stays at "loaded work spec" for more than two minutes, the mover hangs. Delete
the Job, not the Restore. The populator then starts a fresh mover:
`kubectl delete job -n <ns> <job> --context artemis`.

If the last line is "resolved restore source to a snapshot", the mover is copying data. Wait.

## Step 7: Make sure that the restore worked, then resume

```bash
kubectl get pvc -n <ns> <pvc> --context artemis                     # Bound, and a NEW volume name
kubectl get restore -n <ns> <app> -o jsonpath='{.status.phase}{"\n"}' --context artemis   # Completed
kubectl exec -n <ns> <app>-0 --context artemis -- ls -la <mountPath>  # real files, not an empty dir
```

Make sure that the new volume has the current parameters. The DRBD command and how to read it are
in `.agents/references/storage.md` § miroir `quorum: freeze` means DRBD `on-no-quorum io-error`.
Do not recreate a volume only to change its quorum mode.

Run that command in a miroir agent on a node that holds a replica of the volume. The volume has
2 replicas across the control-plane nodes. On a node with no replica, `drbdsetup show` prints
nothing, and that proves nothing. Find the replica nodes (`diskState: UpToDate`) with:

```bash
kubectl get miroirvolume <pv-name> -o jsonpath='{.status.perNode}' --context artemis
```

When the user confirms that the app works, resume the root first and then the app
(`mise run //kube/clusters/artemis:resume-ks flux-system flux-system`, then
`mise run //kube/clusters/artemis:resume-ks <ns> <ks>`).

## A standalone PVC

A few PVCs are not kopiur claims, for example `home-assistant-cache` and `esphome-buildcache`.
They are plain files in the app folder, with no restore path. If you delete one, the app starts on
an empty volume. Do Steps 1 and 2, delete the PVC with the marker, then run `apply-ks` for the app
to create the PVC again.

## After the restore: check for state that did NOT roll back

The PVC comes back at a point in time. Anything that the app keeps outside the PVC does not roll
back. Some apps keep their metadata in the shared Postgres (`database` namespace). For such an app,
the database is current, but the volume is restored and therefore older. The gap between them is
real drift.

`fediverse/apoci` is the visible case. Its blob store is the PVC, and its manifests are rows in
Postgres. Its GC reports the mismatch as `gc: drift reconcile: file missing, no peer holds it`. On
2026-09-09, a restore gap of about 30 minutes left 6 blobs that the database referenced and that
were absent from disk.

Other apps split their data the same way and fail more quietly. After you restore one, find out
what it stores in other places, and look at that first. Do not wait for the fault to show.

To clear the dangling apoci rows, see the `apoci-federation` skill, § Dangling `package_versions` rows after a PVC restore.

## Gotchas

- `Succeeded` is not `restorable`. On 2026-09-09, several snapshots that were marked Succeeded
  failed to restore with `content <id> not found: object not found`. If offset 0 fails, try an
  older one. Frigate needed offset 12, and matter-server needed offset 14.
- A `Failed` Restore is terminal and never retries. A patch to it does nothing. Delete the Restore
  CR and apply the Kustomization again. Or apply one with a different `source.fromPolicy.offset`.
  Suspend the Kustomization first, or Flux resets the offset to 0.
- In readiness checks, do not treat `<app>-populate-*` as the pod of the app. The name prefix
  matches. Also require the PVC to be `Bound`.
- A PVC stuck in `Terminating` is held by the `pvc-protection` finalizer. Some pod still references
  it, `Succeeded` pods included. Delete that pod.
- If you apply while the PVC is still `Terminating`, the StatefulSet sees it as present and does
  not create it again. Wait for it to disappear, then apply.
- A pod can wait in `SchedulingGated` for a few minutes. The ksgate gates of a Postgres app wait for
  the Postgres cluster and its `Database` object. The gates lift without help.
- The first mount on a new node can fail with `DataLoss ... reads blank — refusing to reformat`.
  The DRBD client of that node is not connected yet. The kubelet tries again and the mount
  succeeds. Do not delete or format the volume.
- If you delete a PVC whose workload is at 0 replicas on purpose, the delete only prunes the volume.
  The StatefulSet creates the PVC again when it next starts a pod, and it restores then. This is the
  right way to retire a volume and keep its backup.
- Do not remove `replicas: 0` in the same commit that prunes an app. Flux can apply the HelmRelease
  change before it gets to the prune, so the app scales up for a short time. On a kopiur-backed PVC,
  this starts a full restore of data that you were retiring. This happened with `arcade/eco` on
  2026-09-09. It was `Pending` on a 16Gi restore before the prune caught up. Split the two changes
  across two commits. If you do not split them, shorten the window: wait for the
  `Push OCI Artifact` run on your commit to go green, then run
  `mise run //kube/clusters/artemis:sync-flux ocirepo flux-system`. Do not sync before the run is
  green. The source then still holds the old revision and applies it again
  (`.agents/instructions/commit-style.md` § The sequence, step 5).

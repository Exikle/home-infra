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

Pass `--context artemis` to every `kubectl` and `flux` command below.

## Step 0: Establish the restore path FIRST

When you delete a PVC, you destroy the volume. `miroir` has `reclaimPolicy: Delete`, so the old PV
is gone when the PVC is gone. You cannot undo this.

```bash
kubectl get pvc -n <ns> <app> -o jsonpath='{.spec.dataSourceRef.kind}/{.spec.dataSourceRef.name}{"\n"}' --context artemis
```

- `Restore/<app>`: the kopiur populator restores the volume. Continue.
- Empty: there is no restore path. If you delete the PVC, the data is lost for good. Continue only
  for a cache that rebuilds itself, or when the user explicitly accepts the loss.

Then make sure that a snapshot exists AND is recent:

```bash
kopiur snapshots list -n <ns> --context artemis | grep '^<app>-' | grep Succeeded | head -5
```

`Succeeded` does NOT mean that the snapshot can be restored. See Gotchas. Look at the age too. The
populator has `policy.onMissingSnapshot: Continue`. So a missing snapshot gives a silently EMPTY
volume, not an error.

## Step 1: Stop whatever will fight the scale-down

A scale to 0 does not stay by itself. Find what owns the replica count:

```bash
kubectl get <deploy|sts> -n <ns> <app> -o jsonpath='{.metadata.ownerReferences}' --context artemis
```

| Owner                                                      | What to pause                                              |
| ---------------------------------------------------------- | ---------------------------------------------------------- |
| none (chart resource)                                      | `flux suspend helmrelease -n <ns> <app> --context artemis` |
| an operator CR (`InferenceService`, `PocketIDInstance`, …) | Scale the operator to 0, then the app.                     |

`flux suspend kustomization` is NOT enough for a workload that a chart renders, because
helm-controller restores the replicas. Also, `replicas: null` in app-template means that Flux does
_not_ put the replicas back after a failure. You must scale up by hand.

Record the current replica count now. You need it in Step 4:

```bash
kubectl get <deploy|sts> -n <ns> <app> -o jsonpath='{.spec.replicas}' --context artemis
```

## Step 2: Scale down and confirm the volume is released

The guard blocks `kubectl scale` (rule `kubectl-mutation`). Use the `scale-workload` task. It asks
for confirmation, so it needs `--yes`:

```bash
mise run --yes //kube/clusters/artemis:scale-workload <ns> <deploy|sts>/<app> 0
kubectl get pods -n <ns> --context artemis -o jsonpath="{range .items[?(@.spec.volumes[*].persistentVolumeClaim.claimName=='<pvc>')]}{.metadata.name}{'\n'}{end}"
```

Wait until the second command returns nothing. A pod stuck in `Terminating` holds the volume
forever. Force it: `kubectl delete pod -n <ns> <pod> --force --grace-period=0 --context artemis`.

## Step 3: Delete the PVC

`guard-destructive.sh` blocks `kubectl delete ... pvc`. For a planned recreation with a verified
snapshot, turn off that one rule with the marker. The marker must start the command, as an
environment assignment. A trailing comment does not work:

```bash
I_HAVE_A_KOPIUR_SNAPSHOT=1 kubectl delete pvc -n <ns> <pvc> --wait=false --context artemis
```

A command that starts with `VAR=` matches no allow-list entry, so the user approves it.

The marker turns off ONLY `kubectl-delete-critical`. Every other rule still applies. Do not use the
marker unless you did Step 0.

Wait until the PVC is gone before you continue. See the `Terminating` gotcha below.

## Step 4: Recreate it

The controller that recreates the PVC depends on where the PVC is defined:

| PVC comes from                                                    | Recreate with                                                                      |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `components/kopiur/backup` (has `dataSourceRef`)                  | `flux reconcile kustomization -n <ns> <ks>`                                        |
| app-template `persistence.<name>` (Helm)                          | `flux resume helmrelease …` then `flux reconcile helmrelease -n <ns> <hr> --force` |
| StatefulSet `volumeClaimTemplates` (name ends `-<sts>-<ordinal>`) | Scale the STS back up.                                                             |

On an upgrade with no changes, Helm does not recreate a resource that someone deleted outside Helm.
The `--force` makes Helm put the PVC back.

Then scale back to the ORIGINAL replica count from Step 1. Do not assume 1. Use the same task:
`mise run --yes //kube/clusters/artemis:scale-workload <ns> <deploy|sts>/<app> <replicas>`.

## Step 5: Verify

```bash
kubectl get pvc -n <ns> <pvc> --context artemis                     # Bound, and a NEW volume name
kubectl get restore -n <ns> <app> -o jsonpath='{.status.phase}{"\n"}' --context artemis   # Completed
kubectl exec -n <ns> <pod> --context artemis -- ls -la <mountPath>  # real files, not an empty dir
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
  CR and let Flux create it again. Or apply one with a different `source.fromPolicy.offset`. Suspend
  the Kustomization first, or Flux resets the offset to 0.
- The populator pod can hang. If `<app>-populate-*` runs for many minutes with no new log lines, it
  is stuck, not slow. Delete the pod, and the Job creates a replacement.
- In readiness checks, do not treat `<app>-populate-*` as the pod of the app. The name prefix
  matches. Also require the PVC to be `Bound`.
- A PVC stuck in `Terminating` is held by the `pvc-protection` finalizer. Some pod still references
  it, `Succeeded` pods included. Delete that pod.
- If you reconcile while the PVC is still `Terminating`, Flux sees it as present and does not
  recreate it. Wait for it to disappear, then reconcile.
- If you delete a PVC whose workload is at 0 replicas on purpose, the delete only prunes the volume.
  The PVC comes back `Pending` (`WaitForFirstConsumer`) and restores when it is next scheduled. This
  is the right way to retire a volume and keep its backup.
- Do not remove `replicas: 0` in the same commit that prunes an app. Flux can apply the HelmRelease
  change before it gets to the prune, so the app scales up for a short time. On a kopiur-backed PVC,
  this starts a full restore of data that you were retiring. This happened with `arcade/eco` on
  2026-09-09. It was `Pending` on a 16Gi restore before the prune caught up. Split the two changes
  across two commits. If you do not split them, shorten the window: wait for the
  `Push OCI Artifact` run on your commit to go green, then run
  `mise run //kube/clusters/artemis:sync-flux ocirepo flux-system`. Do not sync before the run is
  green. The source then still holds the old revision and applies it again
  (`.agents/instructions/commit-style.md` § The sequence, step 5).

# Kopiur Restore on Frostlink

Restore a Kopiur-managed PVC from a snapshot in the `r2` ClusterRepository (Cloudflare R2). The
Artemis steps in SKILL.md do not apply here. `mise run //kube/clusters/frostlink:restore-pvc` and
`snapshot-pvc` take different arguments here, and they behave differently.

`.agents/references/openebs-zfs.md` § Restore is the companion doc. Every `kubectl` command pins
`--context frostlink`.

## Rules (reasons in openebs-zfs.md)

Use `mise run --yes //kube/clusters/frostlink:restore-pvc <ns> <ks> <claim> [offset]`. It encodes
the order of the steps, and it makes sure that the restore came from a snapshot. Do not write the
sequence by hand unless the task is broken.

The rules and their reasons are in `.agents/references/openebs-zfs.md` § Restore. That file wins.

## Step 1: Confirm with the user

Ask the user for these:

- The app, the namespace, and the Kustomization name (the task takes all three)
- The PVC
- The snapshot: the latest, or an offset back through the policy
- The reason (corruption, accidental delete, bad upgrade)

A restore destroys the current PVC. Get explicit confirmation first.

## Step 2: Check what is restorable

```bash
kubectl -n <ns> get snapshotpolicy,snapshotschedule,restore --context frostlink
kubectl -n <ns> get snapshot --sort-by=.metadata.creationTimestamp --context frostlink
kubectl -n <ns> get pvc <claim> --context frostlink
```

A healthy policy has recent `Succeeded` snapshots. If the newest snapshot is `Failed`, or the list
is empty, stop. There is nothing to restore. If you delete the PVC, you lose the data.

## Step 3: Run the restore

```bash
mise run --yes //kube/clusters/frostlink:restore-pvc <ns> <ks> <claim>
mise run --yes //kube/clusters/frostlink:restore-pvc <ns> <ks> <claim> 2   # two snapshots older than the latest
```

The task does these steps, in order:

1. It patches the PV to `Retain`.
2. It scales down every workload that mounts the claim, and it records the replica counts.
3. It waits for the pods to go.
4. It deletes the PVC and the stale `Restore` CR.
5. It reconciles the Kustomization, so Flux recreates both.
6. It patches the offset into the new Restore, if you gave one.
7. It scales the workloads back up to drive the populator, and waits for `Bound`.
8. It makes sure that `status.resolved.resolution == Snapshot`. If that is not true, it fails
   loudly.

An offset above 0 is not verified. The task patches the offset after Flux recreated the Restore,
and the Restore pins its source when it is created. After an offset run, make sure that
`.status.claims.<claim>.resolved.snapshotRef.name` names the snapshot that you meant.

## Step 4: Watch it land

```bash
kubectl -n <ns> get restore <claim> -w --context frostlink
kubectl -n <ns> get pods -w --context frostlink
kubectl -n <ns> logs <mover-pod> --tail=30 --context frostlink
```

## Step 5: Verify, then reclaim

Read the state of the claim on the Restore. The task reads only the top-level `status.resolved`:

```bash
kubectl -n <ns> get restore <claim> -o jsonpath='{.status.claims.<claim>.resolved.resolution}' --context frostlink
```

It must print `Snapshot`.

The task prints the retained PV. That PV is the only copy of the state before the restore. Reclaim
it only after the user confirms that the restored data is good:

```bash
mise run --yes //kube/clusters/frostlink:reclaim-pv <pv-name>
```

The task refuses a PV that is not `Released`. It deletes the PV and its `ZFSVolume`.

If you skip this step, the space leaks for good.

## Common issues

- `resolution: NoSnapshot` after a restore: the volume is empty. The old data is still on the
  retained PV. Make sure that a `Succeeded` snapshot exists, then run the task again.
- Restore reports `Completed` in seconds with no mover pod: read `status.claims.<claim>`. It is
  one of two things:
    - `reason: TargetAlreadyBound` means that the PVC was still bound. Nothing ran, and the volume
      was not touched.
    - `resolution: NoSnapshot` means an empty volume, as above.
- PVC stuck `Pending`, `Used By: <none>`: this is `WaitForFirstConsumer`. Scale the workload up.
- PVC stuck `Terminating`: a completed mover pod holds the `pvc-protection` finalizer. Delete that
  pod.
- Mover pod `Init:0/1` with `FailedMount`: the volume is still mounted elsewhere. Scale down.
- `disk quota exceeded`: the mover cache is too small for the data. Raise `KOPIUR_CACHE_CAPACITY`.
- Snapshot stuck deleting with a `snapshot-cleanup` finalizer: ask the user first. Then run
  `mise run --yes //kube/clusters/frostlink:release-snapshot <ns> <name>`. The task refuses a
  Snapshot that is not being deleted. Without the finalizer, kopiur does not clean the snapshot out
  of the repository.
- The whole Kustomization stops reconciling after a restore: `spec.dataSourceRef` is immutable
  after the PVC binds. Flux applies a Kustomization atomically, so one rejected PVC blocks all of
  it. See `.agents/references/openebs-zfs.md` § "No `ssa:` annotation".

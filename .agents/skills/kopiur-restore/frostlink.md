# Kopiur Restore on Frostlink

Restore a Kopiur-managed PVC from a snapshot in the `r2` ClusterRepository (Cloudflare R2). The
Artemis steps in SKILL.md do not apply. `mise run //clusters/frostlink/kubernetes:restore-pvc`
and `snapshot-pvc` take different arguments and behave differently here.

`.agents/references/openebs-zfs.md` § Restore is the companion doc. It carries the rationale for
every rule below. Every `kubectl` pins `--context frostlink`.

## Rules (reasons in openebs-zfs.md)

- Use `mise run //clusters/frostlink/kubernetes:restore-pvc <ns> <ks> <claim> [offset]`. It encodes
  the ordering and asserts that the restore came from a snapshot. Do not hand-roll the sequence
  unless the task is broken.
- An empty restore is silent. A `Restore` CR created before the first snapshot pins
  `resolution: NoSnapshot` forever and provisions an empty volume with `phase: Completed`. See
  § The Restore CR pins its snapshot resolution at creation — permanently.
- Retain the old PV first (the reclaim policy is `Delete`). See § Always retain the old volume first.
- `openebs-zfs` is `WaitForFirstConsumer`, so the workload must scale back up to drive the
  restore. See § `WaitForFirstConsumer` means a restore needs a consumer.
- Do not leave the mover cache at the Kopiur 1Mi default (`KOPIUR_CACHE_CAPACITY`).
  `inheritSecurityContextFrom: pvcConsumer` is backup-only. See § Backups via Kopiur, Known quirks.

## Step 1: Confirm with the user

- The app, the namespace, and the Kustomization name (the task takes all three)
- Which PVC
- Which snapshot: the latest, or an offset back through the policy
- The reason (corruption, accidental delete, bad upgrade)

Restoring destroys the current PVC. Get explicit confirmation first.

## Step 2: Check what is restorable

```bash
kubectl -n <ns> get snapshotpolicy,snapshotschedule,restore --context frostlink
kubectl -n <ns> get snapshot --sort-by=.metadata.creationTimestamp --context frostlink
kubectl -n <ns> get pvc <claim> --context frostlink
```

A healthy policy has recent `Succeeded` snapshots. If the newest snapshot is `Failed`, or the list
is empty, stop. There is nothing to restore, and deleting the PVC would be pure data loss.

## Step 3: Run the restore

```bash
mise run //clusters/frostlink/kubernetes:restore-pvc <ns> <ks> <claim>
mise run //clusters/frostlink/kubernetes:restore-pvc <ns> <ks> <claim> 2   # two snapshots older than the latest
```

The task does this, in order. It patches the PV to `Retain`. It scales down every workload that
mounts the claim, and remembers the replica counts. It waits for the pods to go. It deletes the PVC
and the stale `Restore` CR. It reconciles the Kustomization so Flux recreates both. It applies the
offset, if given. It scales the workloads back up to drive the populator, and waits for `Bound`.
Last, it asserts `status.resolved.resolution == Snapshot` and fails loudly if not.

## Step 4: Watch it land

```bash
kubectl -n <ns> get restore <claim> -w --context frostlink
kubectl -n <ns> get pods -w --context frostlink
kubectl -n <ns> logs <mover-pod> --tail=30 --context frostlink
```

## Step 5: Verify, then reclaim

The task prints the retained PV and the two delete commands. Do not run them until the data is
confirmed good. That PV is the only copy of the pre-restore state. Once verified:

```bash
kubectl delete pv <pv-name> --context frostlink
kubectl -n openebs-system delete zfsvolume <pv-name> --context frostlink
```

Skipping this leaks the space for good. To inspect a restored volume before the app touches it,
make a throwaway pod the first consumer:

```bash
mise run //clusters/frostlink/kubernetes:browse-pvc <ns> <claim>
```

## Common issues

- `resolution: NoSnapshot` after a restore: the volume is EMPTY. The old data is still on the
  retained PV. Delete the Restore CR, confirm that a `Succeeded` snapshot exists, and re-run.
- Restore reports `Completed` in seconds with no mover pod: the same failure.
- PVC stuck `Pending`, `Used By: <none>`: `WaitForFirstConsumer`. Scale the workload up.
- PVC stuck `Terminating`: a completed mover pod holds the `pvc-protection` finalizer. Delete that pod.
- Mover pod `Init:0/1` with `FailedMount`: the volume is still mounted elsewhere. Scale down.
- `disk quota exceeded`: the mover cache is too small for the data. Raise `KOPIUR_CACHE_CAPACITY`.
- Snapshot stuck with a `snapshot-cleanup` finalizer:

    ```bash
    kubectl -n <ns> patch snapshot <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' --context frostlink
    ```

- The whole Kustomization stops reconciling after a restore: `spec.dataSourceRef` is immutable once
  bound, and Flux applies a Kustomization atomically, so one rejected PVC blocks all of it. See
  `.agents/references/openebs-zfs.md` § "No `ssa:` annotation".

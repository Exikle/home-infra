---
name: kopiur-restore
description: Restore a PVC from its Kopiur backup in Cloudflare R2 — including the silent empty-restore failure mode. Use for "restore X from backup", "recover PVC", "roll back X's data", "kopiur restore", "restore from R2", or "the restored volume is empty". Scoped to the Frostlink cluster. This is the default for any restore request. Use `restore-drill` when the question is whether backups work rather than restoring one.
compatibility: Requires the kopiur CRDs and the `r2` ClusterRepository (Cloudflare R2). Writes to a live PVC — the empty-restore failure mode is silent, so verify contents before declaring success.
---

# Skill: Kopiur Restore

Restore a Kopiur-managed PVC from a snapshot in the `r2` ClusterRepository.

`.agents/references/storage.md` § Restore is the companion doc and carries the rationale for
every constraint below. Read it before deviating from this procedure. Every `kubectl` pins
`--context frostlink`.

## Rules (reasons in storage.md)

- **Use `just kube restore <ns> <ks> <claim> [offset]`.** It encodes the ordering and asserts the
  restore came from a snapshot. Do not hand-roll the sequence unless the recipe is broken.
- **An empty restore is silent.** A `Restore` CR created before the first snapshot pins
  `resolution: NoSnapshot` forever and provisions an empty volume with `phase: Completed`:
  § The Restore CR pins its snapshot resolution at creation — permanently.
- **Retain the old PV first** (reclaim policy is `Delete`): § Always retain the old volume first.
- **`openebs-zfs` is `WaitForFirstConsumer`**, so the workload must be scaled back up to drive the
  restore: § `WaitForFirstConsumer` means a restore needs a consumer.
- Mover cache must be at least 2Gi (`KOPIUR_CACHE_CAPACITY`), and `inheritSecurityContextFrom:
  pvcConsumer` is backup-only: § Backups via Kopiur, Known quirks.

## Step 1 — Confirm with the user

- **App**, **namespace**, and the **Kustomization name** (`just kube restore` takes all three)
- **Which PVC**
- **Which snapshot** — latest, or an offset back through the policy
- **Reason** (corruption, accidental delete, bad upgrade)

Restoring destroys the current PVC. Get explicit confirmation before proceeding.

## Step 2 — Check what is actually restorable

```bash
kubectl -n <ns> get snapshotpolicy,snapshotschedule,restore --context frostlink
kubectl -n <ns> get snapshot --sort-by=.metadata.creationTimestamp --context frostlink
kubectl -n <ns> get pvc <claim> --context frostlink
```

A healthy policy has recent `Succeeded` snapshots. If the newest snapshot is `Failed` or the list
is empty, **stop** — there is nothing to restore and deleting the PVC would be pure data loss.

## Step 3 — Run the restore

```bash
just kube restore <ns> <ks> <claim>
```

Add a fourth argument to go further back:

```bash
just kube restore <ns> <ks> <claim> 2   # two snapshots older than latest
```

What the recipe does, in order: patches the PV to `Retain`; scales down every workload mounting
the claim (remembering their replica counts); waits for the pods to go; deletes the PVC and the
stale `Restore` CR; reconciles the Kustomization so Flux recreates both; applies the offset if
given; scales the workloads back **up** to drive the populator; waits for `Bound`; then asserts
`status.resolved.resolution == Snapshot` and fails loudly if it is not.

## Step 4 — Watch it land

```bash
kubectl -n <ns> get restore <claim> -w --context frostlink
kubectl -n <ns> get pods -w --context frostlink
kubectl -n <ns> logs <mover-pod> --tail=30 --context frostlink
```

## Step 5 — Verify, then reclaim

The recipe prints the retained PV and the two commands to delete it. **Do not run them until the
data is confirmed good** — that PV is the only copy of the pre-restore state. Once verified:

```bash
kubectl delete pv <pv-name> --context frostlink
kubectl -n openebs-system delete zfsvolume <pv-name> --context frostlink
```

Skipping this leaks the space permanently.

To inspect a restored volume _before_ the app touches it, make a throwaway pod the first consumer
instead of the app:

```bash
just kube browse-pvc <ns> <claim>
```

## Common Issues

- **`resolution: NoSnapshot` after restore** — the volume is EMPTY. The old data is still on the
  retained PV. Delete the Restore CR, confirm a `Succeeded` snapshot exists, and re-run.
- **Restore reports `Completed` in seconds with no mover pod** — same failure as above.
- **PVC stuck `Pending`, `Used By: <none>`** — `WaitForFirstConsumer`. Scale the workload up.
- **PVC stuck `Terminating`** — a completed mover pod still holds the `pvc-protection` finalizer;
  delete that pod.
- **Mover pod `Init:0/1` with `FailedMount`** — the volume is still mounted elsewhere; scale down.
- **`disk quota exceeded`** — mover cache below 2Gi; raise `KOPIUR_CACHE_CAPACITY`.
- **Snapshot stuck with a `snapshot-cleanup` finalizer**:

    ```bash
    kubectl -n <ns> patch snapshot <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' --context frostlink
    ```

- **Whole Kustomization stops reconciling after a restore** — `spec.dataSourceRef` is immutable
  once bound, and Flux applies a Kustomization atomically, so one rejected PVC blocks all of it.
  See `.agents/references/storage.md` § "No `ssa:` annotation".

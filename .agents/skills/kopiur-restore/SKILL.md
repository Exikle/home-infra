---
name: kopiur-restore
description: Restore a PVC from its Kopiur backup in Cloudflare R2 — including the silent empty-restore failure mode. Use for "restore X from backup", "recover PVC", "roll back X's data", "kopiur restore", "restore from R2", or "the restored volume is empty". Scoped to the Frostlink cluster. This is the default for any restore request. Use `restore-drill` when the question is whether backups work rather than restoring one.
compatibility: Requires the kopiur CRDs and the `r2` ClusterRepository (Cloudflare R2). Writes to a live PVC — the empty-restore failure mode is silent, so verify contents before declaring success.
---

# Skill: Kopiur Restore

Restore a Kopiur-managed PVC from a snapshot in the `r2` ClusterRepository.

`.agents/references/storage.md` § Restore is the companion doc — it carries the full rationale for
every constraint below. Read it before deviating from this procedure.

## Critical Rules

- **Use `just kube restore <ns> <ks> <claim> [offset]`.** It encodes the whole ordering and, most
  importantly, **asserts the restore actually came from a snapshot** before declaring success.
  Do not hand-roll the sequence unless the recipe itself is broken.
- **The `Restore` CR pins its snapshot resolution at creation and never re-evaluates it.** A CR
  created before the app's first snapshot pins `resolution: NoSnapshot` *forever*, and because the
  component sets `onMissingSnapshot: Continue` it then provisions an **empty** volume, runs no
  mover, and reports `phase: Completed`. Always delete and recreate the Restore CR, then assert
  `status.resolved.resolution == Snapshot`.
- **Retain the old PV before deleting the PVC.** The storage class reclaim policy is `Delete`, so
  without flipping the PV to `Retain` an empty restore is unrecoverable data loss.
- **`openebs-zfs` is `WaitForFirstConsumer`.** Nothing is provisioned or populated until a pod
  claims the PVC — the workload must be scaled back **up** to drive the restore. It cannot run
  with the app at zero.
- **Mover cache must be ≥ 2Gi.** Kopiur's default is 1Mi and fails with `disk quota exceeded`.
  The component defaults to 2Gi (`KOPIUR_CACHE_CAPACITY`).
- **`copyMethod: Snapshot`, not `Direct`.** openebs-zfs cannot remount a live volume.
- **`inheritSecurityContextFrom: pvcConsumer` is backup-only** — the webhook rejects it on a
  `Restore`. The component uses `snapshot: {}` there, which replays the UID/GID recorded on the
  snapshot and needs no live pod.
- Local `kubectl` is already scoped to Frostlink by `.mise.toml`. Do not add `--kubeconfig` or
  `--context`, and do not use the k8s MCP tools — they act on Artemis.

## Step 1 — Confirm with the user

- **App**, **namespace**, and the **Kustomization name** (`just kube restore` takes all three)
- **Which PVC**
- **Which snapshot** — latest, or an offset back through the policy
- **Reason** (corruption, accidental delete, bad upgrade)

Restoring destroys the current PVC. Get explicit confirmation before proceeding.

## Step 2 — Check what is actually restorable

```bash
kubectl -n <ns> get snapshotpolicy,snapshotschedule,restore
kubectl -n <ns> get snapshot --sort-by=.metadata.creationTimestamp
kubectl -n <ns> get pvc <claim>
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
kubectl -n <ns> get restore <claim> -w
kubectl -n <ns> get pods -w
kubectl -n <ns> logs <mover-pod> --tail=30
```

## Step 5 — Verify, then reclaim

The recipe prints the retained PV and the two commands to delete it. **Do not run them until the
data is confirmed good** — that PV is the only copy of the pre-restore state. Once verified:

```bash
kubectl delete pv <pv-name>
kubectl -n openebs-system delete zfsvolume <pv-name>
```

Skipping this leaks the space permanently.

To inspect a restored volume *before* the app touches it, make a throwaway pod the first consumer
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
  kubectl -n <ns> patch snapshot <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
  ```

- **Whole Kustomization stops reconciling after a restore** — `spec.dataSourceRef` is immutable
  once bound, and Flux applies a Kustomization atomically, so one rejected PVC blocks all of it.
  See `.agents/references/storage.md` § "No `ssa:` annotation".

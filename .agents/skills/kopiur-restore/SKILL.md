---
name: kopiur-restore
description: Restore a PVC from a kopiur backup or snapshot, to recover an app's data after loss, corruption, or a bad change, or to pull a single file out of a snapshot without disturbing the running app. Use for "restore X from backup", "restore from kopiur", "kopiur restore", "recover PVC", "recover X's data", "roll back X's data", "undo a bad migration", "get the old database out of a snapshot", or "the PVC is empty". This is the default for any restore request. Use `recreate-pvc` only when the volume's StorageClass parameters are the thing being changed, and `restore-drill` when the question is whether backups work rather than restoring one. Covers Artemis and Frostlink.
compatibility: Requires the kopiur CRDs and the shared `ClusterRepository/atlas` secret. The core restore path is plain CRs; the `kubectl kopiur ls|cat|download|browse` plugin is needed only for the single-file path.
---

# Skill: Kopiur Restore

Restore a kopiur-managed PVC from a snapshot in home-infra. Or extract a single file from a
snapshot while the app keeps running.

On Frostlink, read `frostlink.md` in this folder first. Its `restore-pvc` takes
`<ns> <ks> <claim> [offset]`, and it restores from R2 on `openebs-zfs`. The steps below are for
Artemis.

> Read `.agents/references/kopiur.md` first. It covers mover identity, the `restore.yaml` uid
> rules, and why Flux never reconciles a completed `Restore` again.
> `.agents/references/storage.md` § Binding mode explains why a populator restore needs the
> workload scaled back up.

> The direction to scale depends on how the PVC is driven:
>
> - `target.populator` Restore into a new, unbound PVC: scale the workload up. Both
>   StorageClasses are `WaitForFirstConsumer`, so the PVC stays `Pending` until a consumer is
>   scheduled. If the workload stays at 0, the restore deadlocks. A populator gives a volume only
>   to an _unbound_ claim.
> - Existing, bound PVC restored in place: scale to 0. `mise run //kube/clusters/artemis:restore-pvc`
>   does this. The mover pod is the consumer, and the app must not write while its data is
>   replaced.
> - `target.pvcRef` Restore into a pre-created PVC (§ Extract-only recovery): this is not a
>   populator. The mover pod mounts the claim, and it is the first consumer. A new, unbound
>   `miroir` claim binds within seconds after the mover pod schedules. The Restore reaches
>   `Completed` with no reader pod and nothing to scale. Verified 2026-10-15
>   ([#2769](https://git.dcunha.io/Exikle/home-infra/issues/2769)).

The `//kube/clusters/artemis` tasks use `kube/clusters/artemis/kubeconfig` with context `artemis`.
Outside a task, pass `--context artemis` explicitly before you run anything destructive.

Goal: get the data of one PVC back from a kopiur snapshot, or pull specific files out of one.

Success means that the app runs against the restored data, and the user confirmed that the contents
are what they expected. You cannot confirm that yourself. Only the user knows if the restored state
is the right point in time.

Stop when the workload is Running on the restored PVC and you reported which snapshot you used.
After that, do not delete the old PVC, the snapshot, or any `Restore` object. Flux never
reconciles a completed `Restore` again. If you delete it, you remove the only record of what ran.

## Pick the right shape first

There are two very different jobs. If you choose the wrong one, you cause an outage that you did
not need.

| You want                                                      | Use                     | App downtime     |
| ------------------------------------------------------------- | ----------------------- | ---------------- |
| The live PVC's files overwritten from the snapshot (additive) | § Full restore          | Yes, scaled to 0 |
| One file (a database, a config) out of a snapshot             | § Extract-only recovery | None             |

Additive means that files newer than the snapshot stay on the volume.

Most "recover my data" requests are extract-only. If the app runs correctly and you need only rows
or a file from before a bad change, do not scale anything down. Do not touch the live claim.
Restore into a _separate_ PVC and copy out what you need.

## Critical rules

- Do not run `kubectl apply` directly. The repo guard (`.claude/hooks/guard-destructive.sh`, rule
  `kubectl-mutation`) blocks it. This is on purpose, so do not route around it. The recovery PVC
  and Restore go through `mise run //kube/clusters/artemis:apply-ks` from local files, so they
  need no CI round-trip. To clean up, run `mise run //kube/clusters/artemis:delete-ks`. Nothing is
  committed. § Extract-only recovery has a worked example.
- Always use `target.pvcRef`. `target.pvc` creates an owned PVC. Kubernetes garbage-collects that
  PVC when the Restore completes, and that deletes your data. Pre-create the PVC and point
  `pvcRef` at it.
- If the mover namespace already has its own `kopiur-repository-secret`, do not set
  `credentialProjection`. See § Credentials. This is the most likely cause of a stalled restore.
- The mover must run as the owner of the data. Set `spec.mover.securityContext.runAsUser` and
  `runAsGroup`, and `spec.mover.podSecurityContext.fsGroup`, on the Restore. The component
  defaults are in `kopiur.md` (the Mover uid/gid row).
- Flux Kustomizations live in the target namespace of the app. Look up the real name:
  `grep -n "^  name:" kube/clusters/artemis/apps/<ns>/<app>/ks.yaml kube/base/<ns>/<app>/ks.yaml 2>/dev/null`.
- Edit in a worktree. Run `mise run //:wt:new fix/<slug>` first (`AGENTS.md` rule 7).

## Credentials: read this before you write a Restore

The `atlas` ClusterRepository points `encryption.passwordSecretRef` at
`kopiur-system/kopiur-repository-secret`. Namespaces that back up (through
`components/kopiur/secret`) also carry their own identical copy of that secret.

- If `kubectl get secret -n <ns> kopiur-repository-secret --context artemis` finds it (the normal
  case), omit `credentialProjection` entirely. The mover uses the local secret.
- If the secret is not in the namespace, the ClusterRepository must allow it with
  `credentialProjection.allowed: true`. The Restore must also set
  `credentialProjection.enabled: true`. Without the allow on the owner side, `enabled` alone
  fails.

If you set `credentialProjection.enabled: true` when the local secret exists, the restore does not
fall back to the local secret. It requests cross-namespace access, and the ClusterRepository
denies it. The Restore then stays in `Pending` with:

```
CredentialsAvailable=False MissingCredentialsSecret: cross-namespace credential projection denied
```

A good, identical secret sits unused in the namespace. To fix it, delete the field.

## Reading a snapshot without restoring it

`kubectl kopiur ls|cat|download|browse` are read-only. They are the quick path when they work.
But both modes do not work at this time for namespaced snapshots here:

- `--local` fails. `atlas` is a filesystem repository on the NAS export `/mnt/atlas/Kopiur`, and
  only mover pods mount it.
- The default in-cluster session pod fails on the same cross-namespace secret wall as above.

Setting `credentialProjection.allowed: true` on the ClusterRepository unlocks them. Until then,
use § Extract-only recovery.

## Step 1: Confirm

1. Ask for the app and namespace, the PVC, the snapshot, and the reason.
2. Use the table at the top to choose between a full restore and extract-only.
3. For a full restore, warn the user that it overwrites the current PVC files. Get explicit
   confirmation.

## Step 2: Find the snapshot

```bash
kubectl get snapshots.kopiur.home-operations.com -n <ns> --context artemis | grep <app>
```

Names are `<app>-YYYYMMDDHHMMSS` in UTC. Convert the time before you choose. The classic mistake is
to pick a snapshot an hour on the wrong side of the incident. Compare your choice with the `AGE`
column.

The full-restore task takes an offset, not a name. Count the offset in
`kubectl kopiur snapshots list -n <ns> --context artemis`. The newest snapshot is 0.

---

## Extract-only recovery (no downtime)

This restores a snapshot into a throwaway PVC, then copies one file out. It never touches the live
claim or the running app.

### 1. Stage the objects locally

1. Create `recovery/` beside the `ks.yaml` of the app. The app lives under
   `kube/clusters/artemis/apps/<ns>/<app>/` or under `kube/base/<ns>/<app>/`.
2. Put the two objects below in `recovery/recovery.yaml`.
3. Add a `kustomization.yaml` in `recovery/` that lists `recovery.yaml`.

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
    name: <app>-recovery
spec:
    accessModes:
        - ReadWriteOnce
    resources:
        requests:
            storage: <same size as the live claim>
    storageClassName: miroir
---
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
    name: <app>-recovery
spec:
    source:
        snapshotRef:
            name: <snapshot-name>
    target:
        pvcRef:
            name: <app>-recovery
```

There is no `credentialProjection` here. See § Credentials.

Then add a Kustomization document to the `ks.yaml` of the app that points at `./recovery`.

### 2. Apply and watch

Suspend the root first (`AGENTS.md` rule 1). The recovery Kustomization exists only locally, so
there is no target to suspend. Run `apply-ks` from the worktree, or it renders the tree of `main`
(`.agents/instructions/commit-style.md` § The sequence, Step 2):

```bash
mise run //kube/clusters/artemis:suspend-ks flux-system flux-system
mise run //kube/clusters/artemis:apply-ks <ns> <app>-recovery
kubectl get restore -n <ns> <app>-recovery -o jsonpath='{.status.phase}' --context artemis
```

The phase goes from `Restoring` to `Completed`. For a 1Gi claim, this takes about two minutes. The
PVC stays `Pending` only until the mover pod schedules. So do not create the reader first.

- If the Restore stays `Pending`, read `.status.conditions[].message`. It names the cause
  precisely.
- If the Restore goes `Failed`, see § Common issues.

### 3. Copy the file out

```bash
kubectl run -n <ns> <app>-recovery-reader --restart=Never \
  --image=mirror.gcr.io/alpine:latest \
  --overrides='{"spec":{"containers":[{"name":"<app>-recovery-reader","image":"mirror.gcr.io/alpine:latest","command":["sleep","900"],"volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"<app>-recovery"}}]}}'

kubectl exec -n <ns> <app>-recovery-reader -- ls -la /mnt
kubectl cp -n <ns> "<app>-recovery-reader:/mnt/<path>" ./<file>
```

For SQLite, copy all three files (`<db>`, `<db>-shm`, `<db>-wal`). Make sure that each one arrived
with the expected size. A copy without its WAL reads as an older, smaller database. It can also
report `database disk image is malformed`. Do not suppress `kubectl cp` errors, because that hides
this fault.

### 4. Clean up

```bash
kubectl delete pod -n <ns> <app>-recovery-reader --wait=false
mise run //kube/clusters/artemis:delete-ks <ns> <app>-recovery
```

1. Delete `recovery/`.
2. Remove the Kustomization document from `ks.yaml`. Keep the leading `---` on the first remaining
   document.
3. After `delete-ks` finishes, resume the root
   (`mise run //kube/clusters/artemis:resume-ks flux-system flux-system`).

You commit nothing here.

---

## Full restore (replaces the live PVC)

Use this only when you must replace the files of the live claim. Use the task:

```bash
mise run --yes //kube/clusters/artemis:restore-pvc <ns> <app> [offset]
```

`offset` 0 is the latest snapshot, 1 is the one before it, and so on. The task does these steps,
in order:

1. It suspends the Kustomization and the HelmRelease that are both named `<app>` in `<ns>`.
2. It scales the workload to 0 and waits for the pods to go.
3. It runs `kopiur restore --from-policy <app> --offset <offset> --to-pvc <app> --wait`.
4. It resumes, force-reconciles, and waits for the rollout.

The task restores additively. It does not pass `--enable-file-deletion`, so files that were not in
the snapshot stay on the volume. For SQLite, look for stray `-wal` and `-shm` files first. A newer
WAL beside an older database can corrupt it.

The task assumes that the Kustomization, HelmRelease, SnapshotPolicy and PVC all share the name of
the app. If it fails, it leaves the app at 0 replicas with Flux suspended. This is on purpose.
Resume by hand when you know the cause. Afterwards, read the API or the logs of the app. Pod
readiness alone is not enough.

## After any restore into a database-backed app

Apps cache their configuration at boot. If you restore or load data under a running app, restart
it. If you do not, it keeps serving the state that it read at startup. Sonarr and Radarr report
_"No indexers available"_ with indexers in the database, and bazarr loses its language profile.
Running `kubectl rollout restart deployment/<app> -n <ns>` is part of the job.

Make sure that the row counts per table are correct. Do not trust the exit code. A load can report
success and still be wrong.

## Common issues

- Restore stuck `Pending` with `MissingCredentialsSecret`: `credentialProjection` is set, but the
  namespace already has the secret. Remove the field. See § Credentials.
- Snapshot stuck deleting with the `snapshot-cleanup` finalizer: ask the user first. Then run
  `mise run --yes //kube/clusters/artemis:release-snapshot <ns> <name>`. The task refuses a
  Snapshot that is not being deleted. Without the finalizer, kopiur does not clean the snapshot
  out of the repository.
- Mover pod `Init:0/1` with FailedMount: another pod still mounts the volume. Scale to 0 first.
- Restore stuck Pending: make sure that the source snapshot is `Succeeded`, not `Failed`.
- Restore `Failed`, with `kopiaErrorClass: Locked` and
  `mkdir /repository/...: read-only file system` in `.status.failure`: kopia tried to
  auto-compact the repository in the middle of the restore, and restore movers mount it read-only.
  The fault is intermittent, and the snapshot is good. A `Failed` Restore is terminal. Run
  `mise run //kube/clusters/artemis:delete-ks <ns> <app>-recovery`, then run `apply-ks` again. A
  retry completed on 2026-10-15.
- Recovered data vanishes when the Restore completes: you used `target.pvc` instead of
  `target.pvcRef`. Kubernetes garbage-collected the owned PVC.

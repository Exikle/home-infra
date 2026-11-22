# Commit Style — home-infra

Commit hygiene and message format are in `~/.agents/AGENTS.md` § Commit Hygiene and § Commit
Message Format. The always-on rules are in `AGENTS.md` § The rules that apply to every turn. This
file covers only the sequence, and the reason for each step.

## Two-identity signing model

| Identity               | How commits land on main            | Signed by                         |
| ---------------------- | ----------------------------------- | --------------------------------- |
| Exikle (Dixon D'Cunha) | Push directly to main after testing | Exikle's personal SSH signing key |
| Renovate / dusk-bot    | Squash-merged PR                    | git.dcunha.io Instance (SSH key)  |

A squash merge always creates a new server-side commit. The local key of Exikle cannot sign that
commit. So Exikle never uses a PR merge for their own work. PRs are for Renovate only.

## The sequence

The default path is three commands. Run `test-ks` from your worktree.

1. `mise run //kube/clusters/<cluster>:test-ks <ns> <ks>...` suspends the root, suspends each
   Kustomization that you name, and applies each one from the worktree. It refuses to run in the
   main checkout. It prints what is still suspended.
2. Wait until the user tells you that the live deployment works (`AGENTS.md` rule 1 wins).
3. Commit in the worktree (global § Commit Hygiene). Then run
   `mise run --yes //:land <type>/<slug> <cluster>:<ns>/<ks>...`. Name every cluster and
   Kustomization that you tested. `land` asks first, so it needs `--yes`.

`land` does steps 4 and 5 below, then removes the worktree and the remote branch. It refuses to
start unless these are true:

- The branch has commits that `main` does not have.
- The worktree is clean.
- The main checkout is on `main` and is clean.

If `origin/main` moved, `land` rebases the branch. It stops with
"main moved under your test, re-test" when the new commits touch `kube/base/`,
`kube/components/` or the path of a tested Kustomization. `--force` skips that stop. It waits up
to 15 minutes for the artifact of each cluster. If the OCIRepository goes `Ready=False`, or the
`Push OCI Artifact` run fails, it stops and leaves the Kustomizations suspended. Then it resumes the root first and each target after it.

The manual steps below are the fallback. Use them when a task fails, or when `land` stops halfway.
Each step is what the task does.

Step 0. Suspend first, in two calls, root and target. `apply-ks` does not suspend for you.

```bash
mise run //kube/clusters/artemis:suspend-ks flux-system flux-system
mise run //kube/clusters/artemis:suspend-ks <ns> <ks-name>
```

Order does not matter going in, and both are idempotent.

The root matters for this reason: `apply-ks` writes your uncommitted edits. Children reconcile on
their own interval, and a child that reconciles in the middle of a session silently reverts those
edits. Across a dependency chain, a stale child can cascade into deleted CRs and PVCs. The data
survives, but the objects do not. Nothing errors if you forget.

Step 1. Write the changes in your worktree (`AGENTS.md` rule 7). `mise run //:wt:new` branches
from the local `main`. The local `main` falls behind as Renovate merges land. An `apply-ks` from a
stale tree silently reverts those bumps live. So pull first. `<main>` below is the main checkout,
the parent of `.worktrees/` (`dirname "$(git rev-parse --path-format=absolute --git-common-dir)"`):

```bash
git -C <main> pull --ff-only
mise run //:wt:new <type>/<slug>
```

Step 2. Apply to the live cluster from the worktree:
`mise run //kube/clusters/artemis:apply-ks <ns> <ks-name>`. Run it with the worktree as the
working directory, so that mise picks up the task files of the worktree. If you run it from the
main checkout, it builds the manifests of `main` and silently re-applies the old version.

Step 3. Wait until the user tells you that it works. A running pod is not confirmation. Only the
word of the user is.

Step 4. Commit in the worktree (global § Commit Hygiene). Then land the commit on `main` through
the main checkout. The `agent-main-checkout` hk step blocks only agent _commits_ there, not
merges or pushes. Your shell is in the worktree, so name the main checkout explicitly:

```bash
git -C <worktree> fetch origin
git -C <worktree> rebase origin/main          # only if main moved; re-test if it did
git -C <main> status --short --branch         # must be on main, clean
git -C <main> pull --ff-only
git -C <main> merge --ff-only <type>/<slug>
git -C <main> push origin main
```

Run `mise run //:wt:rm <type>/<slug>` after step 5. It refuses unless the branch is an ancestor of
`main`.

Step 5. Wait for the `Push OCI Artifact` run on your commit to go green. Then run
`mise run //kube/clusters/artemis:sync-flux ocirepo flux-system` until the artifact carries your
commit:

```bash
kubectl get ocirepository -n flux-system flux-system --context artemis \
  -o jsonpath='{.status.artifact.metadata.org\.opencontainers\.image\.revision}'
# main@sha1:<git sha> — compare against `git rev-parse HEAD`
```

Use that metadata field, not `.status.artifact.revision`. The latter is
`main@sha256:<OCI digest>`. It is not the git sha, so it can never match your commit. Also, a
watch for a _change_ in it is racy in both directions. If an earlier sync already pulled the new
artifact, the digest never changes again, and the check waits forever on work that is already
done.

Name `flux-system` in the sync. The bare `mise run //kube/clusters/artemis:sync-flux ocirepo`
force-annotates every OCIRepository in the cluster, but step 5 needs exactly one.

An app Kustomization reads its own `ExternalArtifact`, not the OCIRepository
(`app-structure.md` § Per-app artifacts). If the content of the app changed, wait until its
artifact carries your commit too:
`kubectl get externalartifact -n <ns> <app-folder> --context artemis -o jsonpath='{.status.artifact.metadata.org\.opencontainers\.image\.revision}'`.

Then resume, root first and then the target, as two calls:

```bash
mise run //kube/clusters/artemis:resume-ks flux-system flux-system
mise run //kube/clusters/artemis:resume-ks <ns> <ks-name>
```

`resume-ks` refuses to wake a child while the root is still suspended. When it finishes, it warns
if anything else is still suspended.

Do not resume before the artifact is rebuilt. CI builds the OCIRepository, so a resume
immediately after `git push` applies the pre-commit revision and silently reverts what you just
landed. `✔ applied revision` alone proves nothing. Make sure that the live object still carries
your field.

## Frostlink

The sequence is the same. Use `mise run //kube/clusters/frostlink:test-ks <ns> <ks>...`, then
name the Kustomization as `frostlink:<ns>/<ks>` in `land`. The manual fallback is the same
sequence with the Frostlink tasks (`suspend-ks`, `apply-ks`, `sync-flux`, `resume-ks`). Run each
from the worktree.

- `Push OCI Artifact` is one workflow with two jobs, `Artemis` and `Frostlink`. A `changes` job
  diffs the push. The job of a cluster runs when its `apps/` or `components/` under
  `kube/clusters/<cluster>/` changed. Both jobs run when `kube/base/` or `kube/components/`
  changed. A job that does not run shows as skipped. Wait for the job of each cluster that your
  change reaches.
- A change under `kube/base/` or `kube/components/` reaches both clusters in one push. Run
  `test-ks` on both clusters and confirm on each. Then give `land` a target for each cluster.
- Make sure that the artifact carries your commit. Use the Frostlink context:
  `kubectl get ocirepository -n flux-system flux-system --context frostlink -o jsonpath='{.status.artifact.metadata.org\.opencontainers\.image\.revision}'`.
  The artifact names are `exikle/artemis` and `exikle/frostlink`.
- A commit that touches both clusters needs both clusters suspended and resumed. `land` waits for
  the artifact of each cluster that you name.
- It is one node. A change that restarts a core pod (Cilium, CoreDNS, the Envoy front door) is an
  outage of every public site. Say so in the commit, and test it with the user watching.

## Squash rules

- One commit per distinct feature or fix.
- Pre-merge corrections (wrong port, typo, image tag, ExternalSecret mismatch) → amend the local
  commit before pushing.
- Post-push discoveries → a new commit on main, always.

## Renovate PR auto-merge

Renovate PRs squash-merge on their own. The manual-merge command and its batching trap are in
`.agents/references/renovate.md` § Merging a batch, which wins.

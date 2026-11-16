# Commit Style — home-infra

Commit hygiene and message format are in `~/.agents/AGENTS.md` § Commit Hygiene and § Commit
Message Format. The always-on rules are in `AGENTS.md` § The rules that apply to every turn. This
file covers only the sequence, and the reason for each step.

## Two-identity signing model

| Identity               | How commits land on main            | Signed by                        |
| ---------------------- | ----------------------------------- | -------------------------------- |
| Exikle (Dixon D'Cunha) | Push directly to main after testing | Exikle's personal GPG key        |
| Renovate / dusk-bot    | Squash-merged PR                    | git.dcunha.io Instance (SSH key) |

A squash merge always creates a new server-side commit. Exikle's local key cannot sign that
commit. So Exikle never uses a PR merge for their own work. PRs are for Renovate only.

## The sequence

Step 0. Suspend first, in two calls, root and target (`AGENTS.md` rule 1 wins). `apply-ks` does
not suspend for you.

```bash
mise run //clusters/artemis/kubernetes:suspend-ks flux-system flux-system
mise run //clusters/artemis/kubernetes:suspend-ks <ns> <ks-name>
```

Order does not matter going in, and both are idempotent.

The root matters for this reason: `apply-ks` writes uncommitted local edits with
`field-manager=kustomize-controller`. Children reconcile on their own interval. If one reconciles
in the middle of a session, it silently reverts those edits to what is in git. Across a
dependency chain, a child on a stale fetch can re-apply an old revision and cascade into deleted
CRs and PVCs. The data survives, because CNPG `Database` and kopiur defaults retain it, but the
objects do not.

Nothing errors if you forget. The apply succeeds. Minutes later a controller reverts it, and it
looks as if the change never landed.

Step 1. Write the changes in your worktree (`AGENTS.md` rule 7). `mise run //:wt:new` branches from the
local `main`. The local `main` falls behind as Renovate merges land, and `apply-ks` from a stale
tree silently reverts those bumps live. Pull first. `<main>` below is the main checkout, the
parent of `.worktrees/` (`dirname "$(git rev-parse --path-format=absolute --git-common-dir)"`):

```bash
git -C <main> pull --ff-only
mise run //:wt:new <type>/<slug>
```

Step 2. Apply to the live cluster from the worktree: `mise run //clusters/artemis/kubernetes:apply-ks <ns> <ks-name>`. Run it
with the worktree as the working directory, so that mise picks up the task files of the
worktree. If you run it from the main checkout, it builds the manifests of `main` and silently
re-applies the old version.

Step 3. Wait for explicit user confirmation that it works. A running pod is not confirmation.
Only the word of the user is.

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
`mise run //clusters/artemis/kubernetes:sync-flux ocirepo flux-system` until the artifact carries your commit:

```bash
kubectl get ocirepository -n flux-system flux-system \
  -o jsonpath='{.status.artifact.metadata.org\.opencontainers\.image\.revision}'
# main@sha1:<git sha> — compare against `git rev-parse HEAD`
```

Use that metadata field, not `.status.artifact.revision`. The latter is
`main@sha256:<OCI digest>`. It is not the git sha, so it can never match your commit. Also,
watching it merely _change_ is racy in both directions. If an earlier sync already pulled the new
artifact, the digest never changes again, and the check waits forever on work that is already
done.

Name `flux-system` in the sync. The bare `mise run //clusters/artemis/kubernetes:sync-flux ocirepo` force-annotates every
OCIRepository in the cluster, but step 5 needs exactly one.

Then resume, root first and then the target, as two calls:

```bash
mise run //clusters/artemis/kubernetes:resume-ks flux-system flux-system
mise run //clusters/artemis/kubernetes:resume-ks <ns> <ks-name>
```

`resume-ks` refuses to wake a child while the root is still suspended. When it finishes, it warns
if anything else is still suspended.

Do not resume before the artifact is rebuilt. CI builds the OCIRepository, so a resume
immediately after `git push` applies the pre-commit revision and silently reverts what you just
landed. `✔ applied revision` alone proves nothing. Make sure that the live object still carries
your field.

## Frostlink

The sequence is the same, with the Frostlink tasks:
`mise run //clusters/frostlink/kubernetes:suspend-ks flux-system flux-system`, then the same for
`<ns> <ks-name>`, then `apply-ks`, `sync-flux` and `resume-ks`. Run each from the worktree.

- Frostlink has its own CI run, `Push OCI Artifact (Frostlink)`, and it runs only when
  `clusters/frostlink/kubernetes/**` changed. A change to Artemis does not rebuild it, and the
  reverse. Wait for the run of the cluster that you changed.
- Check that the artifact carries your commit with the Frostlink context:
  `kubectl get ocirepository -n flux-system flux-system --context frostlink -o jsonpath='{.status.artifact.metadata.org\.opencontainers\.image\.revision}'`.
  The artifact name is `exikle/frostlink`, not `artemis-cluster`.
- A commit that touches both clusters needs both runs green, and both clusters suspended and
  resumed. Name each cluster in its own task path.
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

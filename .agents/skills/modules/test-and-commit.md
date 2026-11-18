# Module: Test and Commit

The sequence is defined once, in `.agents/instructions/commit-style.md` § The sequence. It covers
suspend, apply, confirm, commit, the wait for the artifact, and resume. Follow it from there. This
module does not restate it. This module adds only what is specific to a session that a skill
drives.

Edit in a worktree. Before the first edit, run `mise run //:wt:new <type>/<slug>` (`AGENTS.md`
rule 7).

On Frostlink, the paths and tasks use `kube/clusters/frostlink/apps/<namespace>/<app>/` and
`mise run //kube/clusters/frostlink:<task>`. Every `kubectl` takes `--context frostlink`. The
sequence is the same as on Artemis. `commit-style.md` § Frostlink has the differences, and it wins.

---

## Before step 2 of the sequence

```bash
# The ks name is metadata.name in ks.yaml, not always <app>
grep "^  name:" kube/clusters/artemis/apps/<namespace>/<app>/ks.yaml

# Render offline, then see what the change would move in the live cluster
mise run //kube/clusters/artemis:render-ks <namespace> <ks-name>
mise run //kube/clusters/artemis:diff-ks <namespace> <ks-name>
```

`flux-validate` covers both in detail.

## Verifying the rollout (after `apply-ks`)

For read-only inspection, use the `-ops` MCP k8s tools. List the tools and match on the server
and tool portion (`.agents/instructions/tooling.md` § MCP servers). Look for the pod list tool,
the resource get tool for the HelmRelease, and the pod log tool. These `kubectl` commands do the
same:

```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl describe helmrelease <app> -n <namespace>
```

Wait for the explicit confirmation of the user before you commit. A running pod is not
confirmation. Only the word of the user is.

## Staging and message

Stage specific files only. Then run `git diff --staged`:

```bash
git add kube/clusters/artemis/apps/<namespace>/<app>/ kube/clusters/artemis/apps/<namespace>/kustomization.yaml
```

- New app: `feat(<namespace>): deploy <app>`
- Convention fix: `fix(<namespace>): bring <app> manifests to convention`

After the push, finish the sequence in `commit-style.md` step 5, and resume, root first. If a
session stops before the resume, Flux stays suspended.

Pull requests are for Renovate only (`commit-style.md` § Two-identity signing model).

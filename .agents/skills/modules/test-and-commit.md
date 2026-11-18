# Module: Test and Commit

The sequence is defined once, in `.agents/instructions/commit-style.md` § The sequence. The default
path is `test-ks`, the user's confirmation, a commit, then `land`. The manual steps there are the
fallback. Follow that file. This module does not restate it. This module adds only what is
specific to a session that a skill drives.

Edit in a worktree. Before the first edit, run `mise run //:wt:new <type>/<slug>` (`AGENTS.md`
rule 7).

`<cluster>` is `artemis` or `frostlink`. On Frostlink, every `kubectl` also takes
`--context frostlink`. The sequence is the same on both clusters. `commit-style.md` § Frostlink
has the differences, and it wins.

The cluster tasks (`test-ks`, `apply-ks`, `suspend-ks`, `resume-ks`, `land`) and git writes stop
for the owner's approval when a subagent runs them. If you are a subagent, stop after `render-ks`
and `diff-ks`, and report to the main session.

---

## Before `test-ks`

Run these before `test-ks` (or, on the manual path, before `apply-ks`):

```bash
# The ks name is metadata.name in ks.yaml, not always <app>
grep "^  name:" kube/clusters/<cluster>/apps/<namespace>/<app>/ks.yaml

# Render offline, then see what the change would move in the live cluster
mise run //kube/clusters/<cluster>:render-ks <namespace> <ks-name>
mise run //kube/clusters/<cluster>:diff-ks <namespace> <ks-name>
```

`flux-validate` covers both in detail.

## Verifying the rollout (after `apply-ks`)

For read-only inspection, use the `-ops` MCP k8s tools on Artemis. List the tools and match on the
server and tool portion (`.agents/instructions/tooling.md` § MCP servers). Look for the pod list
tool, the resource get tool for the HelmRelease, and the pod log tool. These `kubectl` commands do
the same (add `--context frostlink` on Frostlink, where the MCP tools do not reach):

```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl describe helmrelease <app> -n <namespace>
```

Wait for the explicit confirmation of the user before you commit. A running pod is not
confirmation. Only the word of the user is.

## Staging and message

Stage each file by name. List the files first, then add each one, then run `git diff --staged`:

```bash
find kube/clusters/<cluster>/apps/<namespace>/<app> -type f
git add <each file that find listed> kube/clusters/<cluster>/apps/<namespace>/kustomization.yaml
```

- New app: `feat(<namespace>): deploy <app>`
- Convention fix: `fix(<namespace>): bring <app> manifests to convention`

After the commit, run `land` (`commit-style.md` § The sequence). It pushes, waits for the
artifact, and resumes the root first. If you use the manual fallback, finish step 5 of that file
and resume, root first. If a session stops before the resume, Flux stays suspended.

Pull requests are for Renovate only (`commit-style.md` § Two-identity signing model).

# Tooling — Frostlink

Auto-loaded via `CLAUDE.md`. Frostlink has no `.opencode/` directory today; if one is ever added,
load this file there rather than copying its contents.

The rules that apply on every turn are in `AGENTS.md` § The rules that apply to every turn, and
the manifest-authoring conventions (TZ, one OCIRepository per app, routes inline in helmrelease
values) are in `cluster-conventions.md`, which loads when you touch `kubernetes/**`. Neither is
restated here — that duplicate is what would drift.

## just commands

```bash
just kube suspend-ks <ns> <ks>            # suspend ONE ks — run for the root too, it does not bundle
just kube apply-ks <ns> <ks>              # render with flate + kubectl apply --server-side (suspends nothing)
just kube resume-ks <ns> <ks>             # resume ONE ks — root FIRST, then the target
just kube render-local-ks <ns> <ks>       # validate with flate (offline, no cluster needed)
just kube delete-ks <ns> <ks>             # delete a rendered Kustomization
just kube sync <hr|ks|ocirepo|es>        # force-sync every resource of that Flux kind
just kube backup <ns> <claim>             # on-demand Kopiur snapshot, waits for it
just kube restore <ns> <ks> <claim> [off] # restore a PVC from Kopiur (DESTRUCTIVE)
just kube kopiur <suspend|resume>         # suspend/resume the Kopiur controller
just kube browse-pvc <ns> <claim>         # interactive alpine shell on a PVC
just kube debug-node <node>               # sysadmin-profile debug pod
just kube prune-pods                      # drop Failed/Pending/Succeeded pods
just kube view-secret <ns> <secret>
just talos upgrade <version>              # upgrade Talos — REBOOTS the single node = full outage
just bootstrap phase1 | phase2 | tailnet  # one-time bring-up only, confirm-gated
```

Notes that are easy to get wrong:

- **`apply-ks` does not suspend Flux.** It is a plain `flate build | kubectl apply --server-side
--force-conflicts --field-manager=kustomize-controller` (`kubernetes/mod.just`, `apply-ks` and
  `render-local-ks`). Run `suspend-ks` twice first — root `flux-system frostlink-dev` and the
  target — or Flux reconciles over the result. Both suspend recipes act only on the Kustomization
  you name; `resume-ks` refuses to wake a child while the root is still suspended and warns about
  anything left suspended. Sequence and reasons: `commit-style.md`, `flux-patterns.md`.
- **`just talos schematic-id` is `[private]`** — it is called by `just talos upgrade`, not run
  directly.
- **`just kube restore` carries a long ordering rationale in its recipe comments.** Read them, and
  `.agents/references/storage.md` § Restore, before running it. It exists specifically to catch a
  restore that "succeeds" onto an empty volume.
- Full recipe list: `bootstrap/mod.just`, `kubernetes/mod.just`, `talos/mod.just`.

## kubectl and talosctl scoping

`.mise.toml` sets `KUBECONFIG={{config_root}}/kubeconfig` and
`TALOSCONFIG={{config_root}}/talosconfig`. **That only applies where mise is actually activated —
an interactive shell with the mise hook loaded.** It is not a property of the directory.

**In a non-interactive shell — which is what an agent's tool calls are — being in this directory
does nothing.** Outside mise, `~/.zshenv` sets `KUBECONFIG` to a merged Artemis + Frostlink list
whose current context is `artemis`, so bare `kubectl config current-context` prints `artemis` even
from this repo, and a destructive command run that way lands on the wrong cluster with no warning.
Verified 2026-08-22. Safe forms, one command each (`~/.agents/rules/bash-calls.md`):

```bash
just kube <recipe>                                   # kubernetes/mod.just hardcodes --context frostlink
kubectl get pods -A --context frostlink              # flag after the verb, so `Bash(kubectl get:*)` still matches
talosctl version --talosconfig /home/exikle/frostlink/talosconfig   # talosctl has no merged fallback
```

`just` recipes are safe because they pin the context themselves. Bare `kubectl` is not. Do not
add `kubectx` steps or `--kubeconfig` paths to anything in this repo — they are redundant here
and wrong everywhere else.

## MCP servers

Registrations live in `.mcp.json` — three LiteLLM HTTP tiers plus the memini plugin. The
`headersHelper` shells out to `~/.claude/scripts/litellm-headers.mjs`.

| Server            | Capability                                                           |
| ----------------- | -------------------------------------------------------------------- |
| `litellm-ops`     | k8s, Forgejo API, GitHub API, Home Assistant (Artemis-local)         |
| `litellm-general` | SearXNG web search + URL fetch, VictoriaLogs (LogsQL), Context7 docs |
| `litellm-media`   | Arr stack / seerr — Artemis-local, nothing to do with this repo      |
| `memini`          | Cross-session semantic memory                                        |

> **The MCP k8s tools point at Artemis, not Frostlink.** They execute server-side on the LiteLLM
> gateway and cannot see this repo's kubeconfig, so every `k8s-*` call lands on the gateway's own
> context (`artemis`). Treat any MCP k8s result as _Artemis's_ state unless you have proven
> otherwise. **Use local `kubectl` here.** This inverts Artemis's guidance ("prefer the k8s MCP
> tools over shelling out to kubectl") — that advice is Artemis-only.

- Tool names render as `mcp__<server>__<tool>`, and **the server prefix changes when the gateway
  is rewired** — list the session's tools and match on the suffix rather than trusting a name
  written here.
- Web lookups go through the SearXNG tools, never a built-in web-search tool.

## Skills and subagents

Catalog with natural-language triggers: `AGENTS.md` § Skills. It is deliberately not duplicated
here — a second copy is exactly the drift this repo has already been bitten by.

Skills live in `.agents/skills/<name>/SKILL.md`. Claude Code does not discover that path, so every
skill also needs a `.claude/skills/<name>` symlink pointing at it, plus `name:`/`description:`
frontmatter — without the frontmatter a skill can only be invoked by typing its name.

### Subagents in this repo

When to spawn, read-only recon by default, worktrees, and stating the safety rules in the prompt
are in the global `~/.agents/AGENTS.md` § Delegation and context; where findings get published is
`~/.claude/CLAUDE.md` § Artifacts. None of it is restated here. Frostlink-specific additions:

- **Name the Frostlink safety rules in the prompt:** "do not commit, do not push, do not
  `just kube apply-ks`, do not mutate the cluster".
- **Tell it to use local `kubectl --context frostlink`, not MCP.** A subagent doing cluster
  inspection here will otherwise reach for the k8s MCP tools and silently report Artemis's state
  as Frostlink's.
- **`just kube apply-ks` applies the tree of the worktree you run it from** (`AGENTS.md` rule 7).

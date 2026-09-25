# Tooling — Frostlink

Auto-loaded via `CLAUDE.md`. Frostlink has no `.opencode/` directory today; if one is ever added,
load this file there rather than copying its contents.

The rules that apply on every turn are in `AGENTS.md` § The rules that apply to every turn, and
the manifest-authoring conventions (TZ, one OCIRepository per app, routes inline in helmrelease
values) are in `cluster-conventions.md`, which loads when you touch `kubernetes/**`. Neither is
restated here — that duplicate is what would drift.

## just commands

```bash
just kube apply-ks <ns> <ks>              # render with flate + kubectl apply --server-side
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
just bootstrap phase1 | phase2            # one-time bring-up only, both confirm-gated
```

Notes that are easy to get wrong:

- **`apply-ks` does not suspend Flux.** It is a plain `flate build | kubectl apply --server-side
  --force-conflicts`. Flux will happily reconcile over the result, so an applied-but-uncommitted
  change is temporary. There is no `resume-ks` recipe here, and none is needed.
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

**In a non-interactive shell — which is what an agent's tool calls are — `cd`ing here does
nothing.** `cd ~/frostlink && kubectl config current-context` prints `artemis`, and a destructive
command run that way lands on the wrong cluster with no warning. Verified 2026-08-22. Two safe
forms:

```bash
KUBECONFIG=~/frostlink/kubeconfig kubectl ...   # explicit, works anywhere
just kube <recipe>                               # kubernetes/mod.just hardcodes --context frostlink
```

`just` recipes are safe because they pin the context themselves. Bare `kubectl` after a `cd` is
not.
`kubernetes/mod.just` additionally hardcodes `kubectl --context frostlink`. Do not add `kubectx`
steps or `--kubeconfig` paths to anything in this repo — they are redundant here and wrong
everywhere else.

## MCP servers

Registrations live in `.mcp.json` — three LiteLLM HTTP tiers plus the memini plugin. The
`headersHelper` shells out to `~/.claude/scripts/litellm-headers.mjs`.

| Server            | Capability                                                            |
| ----------------- | --------------------------------------------------------------------- |
| `litellm-ops`     | k8s, Forgejo API, GitHub API, Home Assistant (Artemis-local)           |
| `litellm-general` | SearXNG web search + URL fetch, VictoriaLogs (LogsQL), Context7 docs   |
| `litellm-media`   | Arr stack / seerr — Artemis-local, nothing to do with this repo   |
| `memini`          | Cross-session semantic memory                                         |

> **The MCP k8s tools point at Artemis, not Frostlink.** They execute server-side on the LiteLLM
> gateway and cannot see this repo's kubeconfig, so every `k8s-*` call lands on the gateway's own
> context (`artemis`). Treat any MCP k8s result as *Artemis's* state unless you have proven
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

General subagent guidance is in the global `~/.claude/CLAUDE.md` § Subagents, the context cost
that motivates it in § Context Economy, and how to publish a subagent's findings in § Artifacts.
Read them there — none of it is restated here. Frostlink-specific additions:

- **Default to read-only recon.** The commit rule (stage by name, never commit unasked) and the
  apply rule (test, then wait for explicit user confirmation) both require a human in the loop, so
  a subagent should produce a report and let the spawning session apply it.
- **State the safety rules in the prompt every time.** A fresh agent inherits none of this file.
  Spell out "do not commit, do not push, do not `just kube apply-ks`, do not mutate the cluster"
  in the prompt itself.
- **Tell it to use local `kubectl`, not MCP.** A subagent doing cluster inspection here will
  otherwise reach for the k8s MCP tools and silently report Artemis's state as Frostlink's.
- **Edits go in a git worktree** (`~/.claude/CLAUDE.md` § Delegation and context). `just kube
  apply-ks` applies the tree of the worktree you run it from.

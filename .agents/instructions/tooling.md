# Tooling — home-infra

Every agent client loads this file automatically (Claude Code via `CLAUDE.md`, opencode via
`opencode.json` → `instructions`). Anything that both tools need goes here, not in a
tool-specific file.

The rules that apply on every turn are in `AGENTS.md` § The rules that apply to every turn. This
file does not restate them. That duplicate would drift.

## mise tasks

Tasks run with `mise run //<folder>:<task>`. The folder is the task's own path from the repo
root. Each cluster folder sets its own `KUBECONFIG`, `TALOSCONFIG` and `KUBE_CONTEXT` in
`clusters/<cluster>/mise.toml`. The repo root sets none of them, so a cluster task never uses the
wrong cluster.

```bash
mise run //clusters/artemis/kubernetes:suspend-ks <ns> <ks>        # suspend ONE ks; run it for the root too, it does not bundle
mise run //clusters/artemis/kubernetes:apply-ks <ns> <ks>          # render and apply a Kustomization live (suspends nothing)
mise run //clusters/artemis/kubernetes:diff-ks <ns> <ks>           # read-only diff of a local render vs live; exit 1 = differs
mise run //clusters/artemis/kubernetes:resume-ks <ns> <ks>         # resume ONE ks; root FIRST, then the target
mise run //clusters/artemis/kubernetes:sync-flux <res> [name]      # force-sync hr|ks|gitrepo|ocirepo|es; NAME it, or it hits all
mise run //clusters/artemis/kubernetes:render-ks <ns> <ks>         # validate with flate (offline; hidden, runs by name); the root uses flux build against the live cluster
mise run //clusters/artemis/kubernetes:snapshot-pvc [ns] [policy]  # snapshot one policy, a namespace, or all if no args
mise run //clusters/artemis/kubernetes:browse-pvc <ns> <pvc>       # browse a PVC interactively
mise run //clusters/artemis/kubernetes:check-postgres <ns> <app>   # verify an app's Postgres DSN + TLS actually work
mise run //clusters/artemis/kubernetes:prune-pods                  # delete every pod not Running (incl. Pending)
mise run //clusters/artemis/kubernetes:view-secret <ns> <secret>   # print a secret with every value decoded
mise run //clusters/artemis/talos:render-config <node>             # render Jinja2 node config
mise run //clusters/artemis/talos:apply-node <node>                # apply config live (no reboot)
mise run //ai:lint-agents                                          # audit this repo's own agent config for drift
mise run //:wt:new <type>/<slug>                                   # create a worktree + branch from main (AGENTS.md rule 7)
mise run //:wt:rm <type>/<slug>                                    # remove it; refuses unless the branch is an ancestor of main
mise run //:wt:ls                                                  # list worktrees
```

For the full task list, run `mise tasks --all`. A plain `mise tasks` at the repo root lists only
the root tasks. Each folder keeps its tasks in its own `mise.toml`: `clusters/artemis/kubernetes/`,
`clusters/artemis/talos/`, `clusters/artemis/bootstrap/`, `terraform/`, `ansible/` and `ai/`.
`[monorepo] config_roots` in `.mise/config.toml` lists these folders. The root holds the hidden
`log` and `template` tasks and the `wt:` tasks.

Confirm-gated tasks need `mise run --yes`. Every `talos` write verb (`apply-node`, `reboot-node`,
`reset-node`, `shutdown-node`, `upgrade-k8s`, `upgrade-node`), `//terraform:apply`,
`//ansible:apply` and `//clusters/artemis/bootstrap:cluster` ask first. From a non-interactive
shell, they stop with exit 1 (`task requires confirmation but there was nobody to ask`). Put
`--yes` before the task path: `mise run --yes //clusters/artemis/talos:apply-node <node>`. Do not
pipe `printf 'y\n'` into it. The permission classifier blocks that form.

## mise

The configuration file is `.mise/config.toml` (not `.mise.toml`). There is deliberately no
`mise.lock`. `lockfile = false` is set there and globally, every tool is an exact pin that
Renovate bumps, and mise verifies signatures at install. Tools shared with other repos (hk, uv,
python, flate, oxfmt and the rest) come from `include` lines that point at `base.toml` and
`cluster.toml` in <https://git.dcunha.io/exikle/mise-config>, pinned by commit. Edit them there,
not here. `talos` is pinned locally to the running version of the cluster. The repo assumes that
`kubectl`, `helmfile`, `op`, `gum` and `kustomize` are installed globally.

`.mise/config.toml` also pins `LANG` and `LC_ALL` to `C.UTF-8`. Otherwise ansible refuses to
start, because this box exports a locale that it did not generate.

## Git hooks

`hk.pkl` is the single configuration for the pre-commit and commit-msg hooks and for `hk check` /
`hk fix` (no CI runs it here yet). Install once per clone with `hk install --mise` (worktrees
share it). `hk check --all` runs every check by hand. `hk fix --all` applies the formatters. To
skip one step, use `HK_SKIP_STEPS=<name>`, never `--no-verify`. Commit subjects must parse as
conventional commits (`type(scope): subject`).

## MCP servers

There are two agentgateway tiers plus memini. Tool names carry a server prefix that changes per
client. Claude Code renders `mcp__<server>__<tool>`. opencode renders `<server>_<tool>`. Never
hardcode a full tool name from this file. List the tools and match on the server and tool
portion. Within a server, tools are `<target>_<tool>` (for example `victoria-logs_query`).

| Server       | Capability                                                                                                                                                                               |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ai-ops`     | k8s (pods, logs, exec, resources, events, scale), Flux (read-only), Forgejo, GitHub, Home Assistant                                                                                      |
| `ai-general` | Grafana, SearXNG web search + URL fetch, VictoriaLogs (LogsQL), Context7 docs, SparkyFitness, Sonarr / Radarr / Prowlarr, seerr (formerly Jellyseerr). The app and its tools are `seerr` |
| `memini`     | Cross-session semantic memory                                                                                                                                                            |

- For read-only inspection, use the k8s MCP tools, not `kubectl`. They are pre-authenticated and
  structured, and they have no shell quoting to get wrong.
- Web lookups go through the SearXNG tools, never a built-in web-search tool.
- There is no repo-wide `KUBECONFIG` or `TALOSCONFIG`. Each cluster's files live in its own
  folder (`clusters/artemis/kubeconfig`, `clusters/artemis/talosconfig`, gitignored), and
  `clusters/artemis/mise.toml` sets them for the tasks of that cluster. Outside a task, pass
  `--context` explicitly.
- There are six MCP registration files across this machine. A tier change means that you edit
  all of them. `.agents/references/memory-config.md` § Six registration files is canonical.

## Subagents

How and when to delegate is in `~/.agents/AGENTS.md` § Delegation and context. The Bash-call
rules are in `~/.agents/rules/bash-calls.md`. These rules are specific to Artemis:

- Name the forbidden verbs in the brief. "Follow the repo conventions" is not enough. Write
  "do not commit, do not push, do not run `mise run //clusters/artemis/kubernetes:apply-ks`" in those words.
- `mise run //clusters/artemis/kubernetes:apply-ks` applies the tree of the worktree that you run it from (`AGENTS.md` rule 7).

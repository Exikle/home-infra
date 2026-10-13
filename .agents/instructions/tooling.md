# Tooling — Frostlink

Auto-loaded via `CLAUDE.md`. Every-turn rules: `AGENTS.md`; manifest conventions:
`cluster-conventions.md`. Neither is restated here.

## just commands

`just --list kube` (and `talos`, `bootstrap`, `ai`, `wt`) is the recipe list. Easy to get wrong:

- **`apply-ks` suspends nothing.** It is a plain `flate build | kubectl apply --server-side
  --force-conflicts --field-manager=kustomize-controller`. Suspend the root and the target first,
  and resume root first: sequence in `commit-style.md`, reasons in `flux-patterns.md` § Suspend
  before a test-apply. `apply-ks` applies the tree of the worktree you run it from.
- **`just kube sync <hr|ks|ocirepo|es>`** force-syncs every resource of that kind. There is no
  GitRepository — the source is an OCIRepository.
- **`just kube restore <ns> <ks> <claim> [offset]` is DESTRUCTIVE** and its recipe comments carry a
  long ordering rationale. Read them and `storage.md` § Restore first; it exists to catch a
  restore that "succeeds" onto an empty volume.
- **`just talos upgrade <version>` reboots the single node** — a full outage.
- **`just kube render-local-ks <ns> <ks>` is `[private]`** and absent from `just --list kube`; it
  renders offline with flate.
- **`just talos schematic-id` is `[private]`** — `just talos upgrade` calls it.
- **`just bootstrap phase1|phase2|tailnet`** is one-time bring-up, confirm-gated.

## Git hooks

`hk.pkl` is the config for the pre-commit and commit-msg hooks. Install once per clone with
`hk install --mise` (worktrees share it); `hk check --all` / `hk fix --all` run them by hand. Skip
one step with `HK_SKIP_STEPS=<name>`, never `--no-verify`. Commit subjects must parse as
conventional commits.

## kubectl and talosctl scoping

`.mise/config.toml` sets `KUBECONFIG` and `TALOSCONFIG` to the repo-local files, but **only where
mise is activated — an interactive shell with the hook loaded. An agent's tool calls are not.**
There, `~/.zshenv` sets `KUBECONFIG` to a merged Artemis + Frostlink list whose current context is
`artemis`, so bare `kubectl` from this directory hits the wrong cluster with no warning. Always
pass the context (one command per call, `~/.agents/rules/bash-calls.md`):

```bash
just kube <recipe>                                   # kubernetes/mod.just hardcodes --context frostlink
kubectl get pods -A --context frostlink              # flag after the verb, so `Bash(kubectl get:*)` still matches
talosctl version --talosconfig /home/exikle/frostlink/talosconfig   # talosctl has no merged fallback
```

Do not add `kubectx` steps, `--kubeconfig` paths or a `KUBECONFIG=` prefix to anything in this repo.

## MCP servers

Registrations are in `.mcp.json` (`litellm-ops`, `litellm-general`, `litellm-media`) plus the
memini plugin. **The MCP k8s tools point at Artemis** (`AGENTS.md` rule 2): use local `kubectl`
here, which inverts Artemis's "prefer the k8s MCP tools" advice. Tool names render as
`mcp__<server>__<tool>` and the prefix changes when the gateway is rewired — match on the suffix.
Web lookups go through the SearXNG tools, never a built-in web-search tool.

## Skills and subagents

The skill catalog is `ls .agents/skills/` (`AGENTS.md` § Where everything else is); the wiring
rules are in `claude-code-setup.md`. Spawning, worktrees and the safety-rules-in-the-prompt rule
are in the global `~/.agents/AGENTS.md` § Delegation and context. Frostlink additions:

- **Name the Frostlink safety rules in the prompt:** "do not commit, do not push, do not
  `just kube apply-ks`, do not mutate the cluster".
- **Tell it to use local `kubectl --context frostlink`, not MCP**, or it will report Artemis's state
  as Frostlink's.

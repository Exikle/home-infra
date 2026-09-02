# Frostlink — Claude Context

This file is a pointer. All shared agent context lives in `AGENTS.md` and `.agents/`, so that
Claude Code and any other agent client read the same thing. Do not add cluster facts, conventions,
or rules here — put them in `.agents/instructions/` (always loaded) or `.agents/references/`
(on demand).

> **Cluster facts, hardware, networking, namespaces, skills catalog, references index**:
> `AGENTS.md` — read it first, it is canonical.

@AGENTS.md

## Always-Loaded Instructions

@.agents/instructions/tooling.md
@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md

## Claude Code specifics

Behaviour that has no opencode equivalent and therefore stays out of `.agents/`:

- **Hooks** — `.claude/settings.json` wires `SessionStart` (git state injection),
  `PreToolUse:Bash` (destructive-command guard), and `PostToolUse:Edit|Write` (manifest lint).
  **The guard is generated, not hand-written.** `.claude/hooks/guard-destructive.sh` is emitted
  from `.claude/hooks/guard-rules.json` by `.claude/hooks/gen-guards.py` — edit the rule table,
  then run `python3 .claude/hooks/gen-guards.py`. Pre-commit re-runs it with `--check`, so a
  hand-edit fails the commit rather than shipping. This repo has no `.opencode/` directory; if one
  is added, the generator emits the plugin for it automatically.
- **The hooks are shared with Artemis-Cluster.** `session-context.sh`, `validate-manifest.sh`,
  `guard-rules.json` and `gen-guards.py` are vendored copies of
  `~/dotfiles/home/claude/agent-hooks/`; push changes out with that directory's `sync-hooks.sh`.
  Frostlink-only rules (the single-node `talosctl upgrade/reboot` block) live in
  `guard-rules.json` under `"repos": ["frostlink"]`, and `.claude/hooks/guard-repo` names which
  set this repo emits.
- **Skill symlinks** — `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink added or Claude Code cannot see it.
- **Subagent symlinks** — if `.agents/agents/<name>.md` is ever added, it needs a
  `.claude/agents/<name>.md` symlink too. None exist today.

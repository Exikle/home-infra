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
  This repo has no `.opencode/` directory; if one is added, mirror the guard as a plugin there.
- **Skill symlinks** — `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink added or Claude Code cannot see it.
- **Subagent symlinks** — if `.agents/agents/<name>.md` is ever added, it needs a
  `.claude/agents/<name>.md` symlink too. None exist today.

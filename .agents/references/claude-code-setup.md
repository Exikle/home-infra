# Claude Code setup — Frostlink

Mechanics with no opencode equivalent, so they stay out of the shared `.agents/` contract. Read
this when touching a hook, a guard, a rule, or a skill symlink — or when wondering why a guard did
not fire.

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
  Frostlink-only rules — the single-node `talosctl upgrade/reboot` block — live in
  `guard-rules.json` under `"repos": ["frostlink"]`, and `.claude/hooks/guard-repo` names which
  set this repo emits.
- **Path-scoped rules** — `.claude/rules/<name>.md` is a symlink to a file in
  `.agents/instructions/` carrying `paths:` frontmatter. Claude Code loads it only when it touches
  a matching file, which keeps `cluster-conventions.md` (`kubernetes/**`) and `yaml-conventions.md`
  (`kubernetes/**/*.yaml`) out of the always-loaded set. A rule in `.claude/rules/` **without**
  `paths:` loads every session — the same cost as an `@import` — so an instruction file is wired
  exactly one way, never both.

    Unlike Artemis, this repo has **no `opencode.json`**, so there is no second client loading the
    same files unconditionally. The scoping is a pure reduction here.

- **Skill symlinks** — `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink added or Claude Code cannot see it.
- **Subagent symlinks** — if `.agents/agents/<name>.md` is ever added it needs a
  `.claude/agents/<name>.md` symlink too. None exist today.
- **`just ai lint-agents`** (`scripts/check-agent-config.py`) audits all of the above: missing or
  dangling symlinks, skills without `name:`/`description:`, dangling `@imports`, an instruction
  file wired twice or not at all, a reference doc absent from the AGENTS.md index, and an index row
  naming a file that does not exist. Every one of those fails **silently** — a skill with no
  symlink is simply never offered, and nothing errors. It runs in the hk pre-commit hook on any `.agents/`,
  `.claude/`, `AGENTS.md` or `CLAUDE.md` change.

    The frontmatter parser is a regex, not a YAML parser (there is no `yaml` module on this box),
    so it also checks the one YAML mistake this repo actually makes: a **colon-space inside an
    unquoted scalar**. `description: ... upgrades are disruptive: never widen ...` parses as a
    nested mapping, the whole block fails, and the skill silently loses its name and stops being
    invocable. Use an em dash, or quote the value.

- **`just ai eval`** (`scripts/eval-instructions.py`) is the behavioural counterpart: the lint
  proves a file is _wired_, the eval proves the wiring carries meaning. It assembles the real
  context an agent gets — CLAUDE.md with `@` imports expanded, plus the `paths:`-scoped rules
  matching a case's declared file — asks the questions in `.agents/evals/*.yaml`, and scores the
  replies. **`--ab <ref>`** runs the same suite against a git ref and reports regressions, which is
  the honest way to back a claim like "I cut N lines and nothing important went missing". It costs
  tokens, so it is on demand and never in a hook. A single run is noisy, so `--runs N` scores each case N
  times and takes a strict majority (an even split fails) — use it for any `--ab` you intend
  to act on. One FAIL at `--runs 1` means read the reply with `--show-replies`, not that a
  doc regressed.

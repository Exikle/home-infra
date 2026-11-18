# Claude Code setup — home-infra

These mechanics are specific to Claude Code, so they stay out of the shared `.agents/` contract.
opencode has two counterparts: the generated guard `.opencode/plugins/guard-destructive.js` and
the subagent symlinks in `.opencode/agents/`. Read this file when you touch a hook, add a skill
or subagent, or want to know why a guard did not fire.

- There is no `CLAUDE.md` at the repo root. Claude Code reads `AGENTS.md` when a project has no
  `CLAUDE.md`. If someone adds a `CLAUDE.md`, Claude Code stops reading `AGENTS.md`, and
  `lint-agents` fails. The three always-loaded instruction files are `@` imports inside
  `AGENTS.md`.

- Hooks: `.claude/settings.json` wires three hooks. `SessionStart` injects the git state.
  `PreToolUse:Bash` is the destructive-command guard. `PostToolUse:Edit|Write|MultiEdit` lints
  manifests. The guards are generated, not hand-written. `.claude/hooks/gen-guards.py` emits
  both `.claude/hooks/guard-destructive.sh` and `.opencode/plugins/guard-destructive.js` from
  `.claude/hooks/guard-rules.json`. These files are vendored. The master copies are in
  `~/dotfiles/home/claude/agent-hooks/`. To change a guard, edit the rule table there, run
  `sync-hooks.sh` (it copies the files here and regenerates both guards), then commit here.
  Pre-commit runs `gen-guards.py --check`, which also runs every case in
  `.claude/hooks/guard-cases.json` against both guards. So a hand-edit, a half-applied change or
  a rule that breaks a known case fails the commit.
- How the guard reads a command: it joins `\` line breaks, splits the command at `;`, `&&`,
  `||` and `|`, and blanks the text inside quotes. A rule matches only a tool in command
  position. So `grep 'kubectl apply' file` passes, and `kubectl apply` is caught. The body of
  `bash -c '…'` and of a heredoc that feeds a shell is checked. Any other heredoc body is data.
- A subagent that runs a write task (a cluster mise task, any `mise run --yes`, or a git write)
  gets a permission prompt for the user, not a block. The main thread is not asked. Those tasks
  keep their own `confirm` gates. opencode has no prompt, so its plugin skips these rules.
- A rule can carry a scoped `exempt` pattern. `kubectl-delete-critical` has one. If a command
  starts with `I_HAVE_A_KOPIUR_SNAPSHOT=1 kubectl …`, it opts out of _that rule only_. The marker
  anywhere else (a trailing comment, an `echo`) does not count. So a planned PVC
  recreation can run without a blanket hole. Every other rule still fires, `talosctl reset/wipe`
  included. For this reason, the marker is a per-rule `exempt` and not an entry in the global
  `always_allow`. The procedure that it exists for is `.agents/skills/recreate-pvc/SKILL.md`. The
  marker is not a general-purpose override. Without a verified snapshot, it means nothing. The
  rule matches the bare word `pvc`. So it also fires on unrelated objects _named_ `pvc-…`, for
  example a MiroirVolume.
- `session-context.sh`, `validate-manifest.sh`, `guard-rules.json` and `gen-guards.py` are
  vendored copies (copies kept in this repo) of `~/dotfiles/home/claude/agent-hooks/`. To push
  changes out, run the `sync-hooks.sh` of that directory. Repo-specific rules carry a per-rule
  `"repos": [...]` field in `guard-rules.json`. `.claude/hooks/guard-repo` names the set that
  this repo emits. This repo emits `home-infra`, the set for both clusters. Its
  `talosctl upgrade/reboot/shutdown` rule blocks any `talosctl` call that does not name Artemis.
  The reason is that a bare call can hit the single Frostlink node.
- Skill symlinks: `.claude/skills/<name>` → `.agents/skills/<name>`. A new skill needs the
  symlink. Without it, Claude Code cannot see the skill. opencode reads `.agents/skills/`
  directly.
- Subagent symlinks: `.claude/agents/<name>.md` → `.agents/agents/<name>.md`. opencode has the
  same link in its own folder: `.opencode/agents/<name>.md` → `.agents/agents/<name>.md`. A new
  subagent needs both links. `lint-agents` checks only the `.claude/agents/` link, so it does not
  catch a missing `.opencode/agents/` link.
- The subagents in `.agents/agents/` have no `model:` line, on purpose. They inherit the model of
  the session. Both clients read the same file, and the two clients name models differently. In
  opencode, `model: haiku` fails with `Model not found: haiku/.` (tested 2026-11-18, #3393).
- Path-scoped rules: `.claude/rules/<name>.md` is a symlink to a file in `.agents/instructions/`
  that carries `paths:` frontmatter. Claude Code loads such a rule only when it touches a matching
  file. So `cluster-conventions.md`, `yaml-conventions.md` and `frostlink.md` stay out of the
  always-loaded set. Each file's `paths:` frontmatter lists the folders that load it. A rule in
  `.claude/rules/` without `paths:` loads every session. That costs the same as an `@import`. So
  wire an instruction file exactly one way, never both. opencode has no equivalent.
  `opencode.json` globs `.agents/instructions/*.md` and loads every one of them
  unconditionally, frontmatter and all.
- `mise run //ai:lint-agents` (`scripts/check-agent-config.py`) audits all of the above. It finds
  these faults:
    - Invalid frontmatter YAML.
    - Missing or dangling symlinks under `.claude/`.
    - Skills and subagents without `name:`/`description:`/`mode:`.
    - Dangling `@imports`.
    - An instruction file wired twice or not at all.
    - A reference doc absent from the AGENTS.md index.
    - An index row that names a file that does not exist.
    - An `opencode.json` instructions glob that matches nothing.

    It runs in the hk pre-commit hook on any change to `.agents/`, `.claude/`, `AGENTS.md` or
    `opencode.json`. The original check functions were mutation-tested. Someone broke them
    deliberately and made sure that they fire. Nobody mutation-tested the frontmatter-YAML check.
    The mutation test matters for this reason. A checker that crashes also exits non-zero.
    Without the test, such a checker looks like a working gate.

- `mise run //ai:eval` (`scripts/eval-instructions.py`) is the behavioural counterpart to
  `lint-agents`. The lint proves that a file is _wired_. The eval proves that the wiring carries
  meaning. It assembles the real context that an agent gets. That context is AGENTS.md with `@`
  imports expanded recursively, plus the `paths:`-scoped rules that match the declared file of a
  case. The eval asks the questions in `.agents/evals/*.yaml` and scores the replies. `--ab <ref>`
  runs the same suite against a git ref and reports regressions. That is the only honest way to
  back a claim that a cut lost nothing important. The eval costs tokens, so it runs on demand and
  never in a hook. `--show-context` dumps the context that it built. `--show-replies` prints the
  reply behind each failure.

    The eval is built to avoid two traps. The first trap comes from the implementation that it
    was modelled on (ionfury/homelab `instruction-eval`). That implementation never loads a root
    instruction file at all. It primes the model with a paraphrase that already contains the
    answers. So every constraint probe passes for the wrong reason. This eval refuses to run if
    the assembled context is under 6KB. The second trap is to score `forbidden` by naive
    substring. That is wrong, because a correct answer usually has to name the thing to rule it
    out ("SOPS is fully removed", "no `git add .`"). The scorer counts only an _affirmative_ use.
    It checks for negation on both sides of the match. `scripts/test-eval-scorer.py` pins both
    directions offline, and it runs in the hk pre-commit hook.

    A single run is noisy. Cases flip between runs of the same unchanged suite. `--runs N` takes
    a strict majority of N samples. An even split fails. If you intend to act on an `--ab` run,
    raise `--runs`. If a case FAILs once at `--runs 1`, read the reply with `--show-replies`. One
    FAIL is a prompt to read the reply, not a verdict.

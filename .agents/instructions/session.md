# Session Journal — Frostlink

Journal format and the `## Current State` convention: global `~/.agents/AGENTS.md` § Memory.
What survives compaction: `~/.claude/CLAUDE.md` § Compaction. Not repeated here.

## Repo specifics

- The journal is `.claude/session-journal.md`, gitignored and machine-local, so it can hold detail
  that would be inappropriate in a public commit message.
- **The compaction hooks are global, not repo-level.** A `PreCompact` hook in
  `~/.claude/settings.json` trims `## Log` to its newest 250 lines once the file passes 300; a
  `SessionStart` `compact` hook re-injects only `## Current State`. Do not prune by hand.
- Because there is no staging cluster, the WHY behind a live-cluster change matters more than
  usual. Record what was applied with `just kube apply-ks`, and what the user confirmed. An
  applied-but-uncommitted change is temporary — Flux reconciles over it — so an unrecorded one
  vanishes with no trace that it was ever tested.
- **Single node, no failover.** Any entry covering a Talos or Kubernetes upgrade should say what
  the outage window was and whether the node came back clean, because there is no second node to
  compare against next time.

## memini vs `.agents/`

- **memini** gets non-obvious operational discoveries — a quirk, a failure mode, a workaround that
  would cost real time to re-derive.
- **`.agents/`** gets conventions, architecture, and policy — anything a future agent should read
  _before_ starting work, version-controlled and reviewable. Semantic memory is only found by
  searching, so it is never read pre-emptively.

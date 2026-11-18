# Session Notes — home-infra

Journal format and the memini and Stop-hook rules are in `~/.agents/AGENTS.md` § Memory. Only
what is specific to this repo lives here.

- (Claude Code) The journal hooks are global (`~/.claude/settings.json`), not in this repo. A
  `PreCompact` hook trims the log to its newest 250 lines and keeps one `.bak`. Do not prune by
  hand. After a compaction, a `SessionStart` `compact` hook re-injects only `## Current State`.
  Keep that section current.
- There is no staging cluster, so the reason for a live change matters more than usual. Record
  what you applied live with `test-ks` or `apply-ks`, and on which cluster. Also record what the
  user confirmed, and anything left suspended.
- Frostlink is one node with no failover. A journal entry for a Talos or Kubernetes upgrade says
  what the outage window was and whether the node came back clean. There is no second node to
  compare against next time.
- memini gets non-obvious operational discoveries: a quirk, a failure mode, or a workaround that
  costs real time to work out again. `.agents/` gets conventions, architecture and policy. If a
  future agent must read a fact _before_ it starts work, put the fact in a version-controlled
  instruction, reference or skill file, not in semantic memory.

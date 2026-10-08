# Session Journal — Frostlink

The journal format, the entry template, and the `## Current State` convention are defined once in
the global `~/.agents/AGENTS.md` § Memory; what survives a compaction is `~/.claude/CLAUDE.md`
§ Compaction, and where a plan or audit goes when a later session will need it is
`~/.claude/CLAUDE.md` § Artifacts. They are not repeated here — a second copy is exactly the drift
this repo has already been bitten by.

## Repo specifics

- The journal is `.claude/session-journal.md`. `.claude/.gitignore` denies everything by default,
  so it is **gitignored** and never leaves this machine — it can hold detail that would be
  inappropriate in a public commit message.
- **The compaction hooks are global, not repo-level.** This repo's `.claude/settings.json` wires
  none, but `~/.claude/settings.json` fires in every repo: a `PreCompact` hook trims `## Log` to
  its newest 250 lines once the file passes 300 (one `.bak` kept), and a `SessionStart` `compact`
  hook re-injects only `## Current State`. Keep that section current; do not prune by hand.
- Because there is no staging cluster, the WHY behind a live-cluster change matters more than
  usual. Record what was applied with `just kube apply-ks`, and what the user confirmed. An
  applied-but-uncommitted change here is temporary — Flux reconciles over it — so an unrecorded
  one vanishes with no trace that it was ever tested.
- **Single node, no failover.** Any entry covering a Talos or Kubernetes upgrade should say what
  the outage window was and whether the node came back clean, because there is no second node to
  compare against next time.

## memini — lessons

Load and save rules are in the global context. The repo-specific split:

- **memini** gets non-obvious operational discoveries — a quirk, a failure mode, a workaround that
  would cost real time to re-derive. The CSINode topology-key trap and the `POSTGRES_CERT_ENCODING`
  rustls failure are the shape of thing that belongs there.
- **`.agents/`** gets conventions, architecture, and policy. Anything a future agent should read
  _before_ starting work belongs in an instruction, reference, or skill file, where it is
  version-controlled and reviewable — not in semantic memory, which is only found by searching for
  it and so is never read pre-emptively.

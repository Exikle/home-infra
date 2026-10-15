# Commit Style — Frostlink

Commit hygiene and the message format are in the global `~/.agents/AGENTS.md` § Commit Hygiene
and § Commit Message Format. This file covers only the Frostlink sequence and signing model.

## Two-identity signing model

| Identity               | How commits land on main            | Signed by                        |
| ---------------------- | ----------------------------------- | -------------------------------- |
| Exikle (Dixon D'Cunha) | Push directly to main after testing | Exikle's personal GPG key        |
| Renovate / dusk-bot    | Squash-merged PR                    | git.dcunha.io Instance (SSH key) |

Squash merge always creates a new server-side commit — it cannot be signed by Exikle's local key. So Exikle **never** goes through a PR merge for their own work. PRs are for Renovate only; to merge one by hand, use the `triage-renovate` skill.

---

## Exikle workflow — always test before committing

This repo has no staging cluster. `main` reconciles directly to production.

1. Write changes locally
2. Suspend the root **and** the target — two calls, order does not matter, both idempotent — then
   apply to the live cluster. `apply-ks` suspends nothing; skip a suspend and Flux silently
   reverts the edit (`flux-patterns.md` § Suspend before a test-apply):

    ```bash
    just kube suspend-ks flux-system flux-system
    just kube suspend-ks <ns> <ks-name>
    just kube apply-ks <ns> <ks-name>
    ```

3. Wait for **explicit user confirmation** that it works. Never commit or push before it.
4. Commit and push directly to `main`.
5. After push, once CI has rebuilt the artifact: `just kube sync ocirepo` until the `flux-system`
   digest moves, then resume — **root first, then the target**, as two calls:

    ```bash
    just kube resume-ks flux-system flux-system
    just kube resume-ks <ns> <ks-name>
    ```

    Do not resume before the artifact is rebuilt — that applies the pre-commit revision and
    reverts what you just landed. `resume-ks` refuses a child while the root is still suspended.

---

## Squash rules

- Squash by logical change — one commit per distinct feature/fix
- Pre-merge corrections (wrong port, typo, image tag, ExternalSecret mismatch) → amend the local commit before pushing
- Post-push discoveries → new commit on main, always

## Branch naming (worktree branches)

```text
feat/network-envoy-gateway
fix/cert-manager-cloudflare-token
chore/flux-update
```

Scope to namespace when relevant.

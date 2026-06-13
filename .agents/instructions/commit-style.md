# Commit Style — Frostlink

## Workflow — always test before committing

This repo has no staging cluster. `main` reconciles directly to production.

1. Write changes locally
2. Apply to live cluster: `talosctl` or `kubectl apply` as appropriate
3. Wait for **explicit user confirmation** that it works
4. Create branch, commit, push, open PR using mcp-forgejo (repo: `Exikle/frostlink`, base: `main`).

5. Enable auto-merge (squash) via mcp-forgejo — set `merge_when_checks_succeed: true`, `delete_branch_after_merge: true`, strategy `squash`.

6. Switch back to main and delete **local** branch only (Forgejo deletes the remote after merge):

    ```bash
    git checkout main && git branch -d <branch>
    ```

**Never commit or push until the user explicitly confirms the live deployment works.**

## Squash Rules

- Squash by logical change — one commit per distinct feature/fix
- Pre-merge corrections (wrong port, typo, image tag) → squash into original commit
- Post-merge discoveries → new commit on a new PR, always

## Commit Message Format

Semantic prefix scoped to namespace:

```text
feat(network): deploy envoy-gateway
fix(cert-manager): correct cloudflare api token secret key
chore: update flux-operator to v0.53.0
docs: update AGENTS.md bootstrap order
refactor(external-secrets): add 1password clusterissuer secret
```

- Title-only is fine for small changes
- Explain WHY in the body only when genuinely non-obvious
- No `Co-Authored-By` trailer — ever
- No `--no-verify` — fix the hook instead

## Staging Rules

- Always stage specific files by name — never `git add .` or `git add -A`
- Run `git diff --staged` before committing — check for secrets, debug output, unintended files

## PR Branch Naming

```text
feat/network-envoy-gateway
fix/cert-manager-cloudflare-token
chore/flux-update
```

Scope to namespace when relevant.

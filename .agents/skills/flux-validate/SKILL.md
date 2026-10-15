---
name: flux-validate
description: Validate and render cluster manifests locally before committing — build the kustomization, diff against the live cluster, and catch schema and substitution errors that would otherwise fail reconciliation. Use for "validate manifests", "render kustomization", "flux diff", or a pre-commit check on a manifest change. Scoped to the Frostlink cluster.
---

# Skill: Flux Validate

Validate and diff Flux manifests offline before committing, using `flate` (on PATH via `mise`).

**Always validate before test-applying.** `main` reconciles directly to production.

## Quick Render (single kustomization)

```bash
just kube render-local-ks <namespace> <ks-name>
```

This runs `flate build ks --namespace <namespace> --output yaml <ks-name>` and prints the rendered manifests. Catches schema errors, missing references, and HelmRelease value mistakes.

The root (`render-local-ks flux-system flux-system`) is the exception: flux-operator generates it,
so flate cannot see it. The recipe runs `flux build kustomization` against the live root instead,
which needs the cluster.

The `<ks-name>` is `metadata.name` from the app's `ks.yaml`, not the directory name.

## Full Test Suite

```bash
flate test all --path ./kubernetes
```

Runs pytest-style `PASS`/`FAIL`/`SKIPPED` per resource. Exit code non-zero on any failure.

Add `--allow-missing-secrets` to skip ExternalSecret-backed secret refs (1Password secrets don't exist offline):

```bash
flate test all --path ./kubernetes --allow-missing-secrets
```

## Diff Against Main (changed-only)

Use a baseline worktree under `.worktrees/` (never `/tmp`):

```bash
git worktree add --detach .worktrees/baseline main
flate diff ks --path ./kubernetes --path-orig .worktrees/baseline/kubernetes
git worktree remove .worktrees/baseline
```

Changed-only mode reconciles only the subtree a change touches.

## List All Kustomizations

```bash
flate get ks --path ./kubernetes
```

## Build a Specific HelmRelease

```bash
flate build hr --namespace <namespace> --output yaml <helmrelease-name>
```

## Validate Workflow (pre-commit checklist)

1. `just kube render-local-ks <ns> <ks>` — render the changed kustomization
2. Review output for unexpected changes
3. `flate test all --path ./kubernetes --allow-missing-secrets` — full suite
4. If tests pass: continue with `modules/test-and-commit.md`

## Notes

- `flate` marks ExternalSecret-backed Secrets that have a declared producer `Ready / "skipped"`, so `--allow-missing-secrets` is rarely needed.
- OCI sources (app-template, etc.) need network access to pull charts.

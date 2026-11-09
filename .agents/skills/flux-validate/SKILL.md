---
name: flux-validate
description: Validate and render cluster manifests locally before committing — build the kustomization, diff against the live cluster, and catch schema and substitution errors that would otherwise fail reconciliation. Use for "validate manifests", "render kustomization", "flux diff", or a pre-commit check on a manifest change. Scoped to the Frostlink cluster.
---

# Skill: Flux Validate

Validate and diff Flux manifests offline before committing, using `flate` (on PATH via `mise`).

**Always validate before test-applying.** `main` reconciles directly to production.

## Setup

`.mise/config.toml` sets `FLATE_PATH` (the `kubernetes/apps` entry path) and `FLATE_SUPPLY`, so
flate needs no flags here. Run it through `mise exec -- flate ...` so you get the pinned version.

This cluster syncs from an OCIRepository, so flate cannot build the `flux-system` source itself.
It also cannot read a Secret that an ExternalSecret creates. `scripts/flate-supply.yaml` holds
placeholders for both. When a render stops on `<kind> <ns>/<name> not found`, add that object
to the file.

The `DisableChartDigestTracking` gate is not set on helm-controller here, so
`FLATE_DISABLE_CHART_DIGEST_TRACKING` stays unset. If you add the gate in `flux-instance`, set
the variable too.

`--allow-missing-secrets` no longer exists.

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
flate test all
```

This prints one result per resource. The exit code is non-zero on any failure or blocked resource.

## Diff Against Main (changed-only)

Use a baseline worktree under `.worktrees/` (never `/tmp`):

```bash
git worktree add --detach .worktrees/baseline main
flate diff ks --path-orig .worktrees/baseline/kubernetes/apps
git worktree remove .worktrees/baseline
```

Changed-only mode reconciles only the subtree a change touches.

## List All Kustomizations

```bash
flate get ks
```

## Build a Specific HelmRelease

```bash
flate build hr --namespace <namespace> --output yaml <helmrelease-name>
```

## Validate Workflow (pre-commit checklist)

1. `just kube render-local-ks <ns> <ks>` — render the changed kustomization
2. Review output for unexpected changes
3. `flate test all` — full suite
4. If tests pass: continue with `modules/test-and-commit.md`

## Notes

- A Secret that an ExternalSecret creates is not readable offline. Where a `postBuild.substituteFrom` or `valuesFrom` needs it, flate blocks the resource until `scripts/flate-supply.yaml` supplies a placeholder.
- OCI sources (app-template, etc.) need network access to pull charts.

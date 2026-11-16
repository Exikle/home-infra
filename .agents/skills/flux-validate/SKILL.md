---
name: flux-validate
description: Validate and render cluster manifests locally before committing — build the kustomization, diff against the live cluster, and catch schema and substitution errors that would otherwise fail reconciliation. Use for "validate manifests", "render kustomization", "flux diff", or a pre-commit check on a manifest change. Covers Artemis and Frostlink.
---

# Skill: Flux Validate

Validate and diff Flux manifests offline before you commit, with `flate` (already available through `mise`).

Always validate before you commit. `main` reconciles directly to production.

On Frostlink, use `mise run //kube/clusters/frostlink:render-ks` and `:diff-ks` the same
way, and pass `--path kube/clusters/frostlink` to the `flate` commands.

## Quick Render (single kustomization)

```bash
mise run //kube/clusters/artemis:render-ks <namespace> <ks-name>
```

This runs `flate build ks --namespace <namespace> --output yaml <ks-name>` and prints the rendered manifests. It catches schema errors, missing references, and HelmRelease value mistakes.

The root (`render-ks flux-system flux-system`) is the exception. flux-operator generates it, so
flate cannot see it. The task runs `flux build kustomization` against the live root instead,
which needs the cluster.

The `<ks-name>` is `metadata.name` from the `ks.yaml` of the app, not the directory name.

## Full Test Suite

```bash
flate test all --path kube/clusters/artemis
```

This prints a pytest-style `PASS`/`FAIL`/`SKIPPED` result per resource. The exit code is non-zero on any failure.

Add `--allow-missing-secrets` to skip ExternalSecret-backed secret refs (1Password secrets do not exist offline):

```bash
flate test all --path kube/clusters/artemis --allow-missing-secrets
```

## Diff Against the Live Cluster

```bash
mise run //kube/clusters/artemis:diff-ks <namespace> <ks-name>
```

This is read-only. It renders locally with `flate`, then runs `kubectl diff --server-side`, which is a server-side
**dry-run apply**. The API server does its own defaulting before it compares. Defaulted fields
never show up as drift. A hand-rolled render-vs-live comparison cannot avoid that. `dyff` renders the output,
so a change appears as a field path rather than a line number.

Exit codes: **0** means no differences. **1** means differences found _or_ the render failed. You tell the two apart
by the output, not by the code. Drift ends on `WARN Differences found`, and a bad ks name
ends on `flate error:`.

Run this check _before_ `suspend-ks` + `apply-ks`, to see what a change would actually
move. It is not the same as `flate diff` below. This one compares local against **the cluster**,
and `flate diff` compares local against **main**.

## Diff Against Main (changed-only)

```bash
git worktree add --detach /tmp/artemis-baseline main
flate diff ks --path kube/clusters/artemis --path-orig /tmp/artemis-baseline/kube/clusters/artemis
git worktree remove /tmp/artemis-baseline
```

Changed-only mode reconciles only the subtree that a change touches. It is fast even on large repos.

## List All Kustomizations

```bash
flate get ks --path kube/clusters/artemis
```

## Build a Specific HelmRelease

```bash
flate build hr --namespace <namespace> --output yaml <helmrelease-name>
```

## Validate Workflow (pre-commit checklist)

1. Run `mise run //kube/clusters/artemis:render-ks <ns> <ks>` to render the changed kustomization.
2. Review the output for unexpected changes.
3. Run `mise run //kube/clusters/artemis:diff-ks <ns> <ks>` to see what the change would actually move in the cluster.
4. Run `flate test all --path kube/clusters/artemis --allow-missing-secrets` for the full suite.
5. If the tests pass, continue with `.agents/skills/modules/test-and-commit.md`. The sequence is in
   `.agents/instructions/commit-style.md` § The sequence: suspend root and target, apply, wait for the
   user, commit, wait for the artifact, resume.

## Notes

- `flate` handles ExternalSecrets gracefully. If the Secret has a declared producer (ExternalSecret), flate marks it `Ready / "skipped"` instead of failing. You do not need `--allow-missing-secrets` in most cases.
- This cluster does not use SOPS ciphertext (all secrets come from 1Password ExternalSecret), so you never need decryption offline.
- OCI sources (app-template, and others) need network access to pull charts. Run with the network available.

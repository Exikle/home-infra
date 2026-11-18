---
name: flux-validate
description: Validate and render cluster manifests locally before committing — build the kustomization, diff against the live cluster, and catch schema and substitution errors that would otherwise fail reconciliation. Use for "validate manifests", "render kustomization", "flux diff", or a pre-commit check on a manifest change. Covers Artemis and Frostlink.
---

# Skill: Flux Validate

Validate and diff Flux manifests offline before you commit. Use `flate`. `mise` already supplies it.

Always validate before you commit. `main` reconciles directly to production.

On Frostlink, use `mise run //kube/clusters/frostlink:render-ks` and `:diff-ks` the same way. Pass
`--path kube/clusters/frostlink` to the `flate` commands.

## Quick Render (single kustomization)

```bash
mise run //kube/clusters/artemis:render-ks <namespace> <ks-name>
```

This task runs `flate build ks --namespace <namespace> --output yaml <ks-name>` and prints the
rendered manifests. It catches schema errors, missing references, and mistakes in HelmRelease
values.

The root (`render-ks flux-system flux-system`) is the exception. flux-operator generates it, so
flate cannot see it. The task runs `flux build kustomization` against the live root instead. That
needs the cluster.

The `<ks-name>` is `metadata.name` from the `ks.yaml` of the app, not the directory name.

## Full Test Suite

```bash
flate test all --path kube/clusters/artemis
```

This prints a pytest-style `PASS`/`FAIL`/`SKIPPED` result per resource. The exit code is non-zero
on any failure.

Run it without `--allow-missing-secrets` first. flate already skips a missing Secret that an
in-repo ExternalSecret declares with a static target name (see Notes).

Use `--allow-missing-secrets` only as a fallback, when a failure names a Secret that exists only in
the live cluster. The flag soft-skips ALL source auth Secrets and all HelmRelease `valuesFrom`
Secret and ConfigMap refs. So it can hide a real error, such as a wrong `valuesFrom` name. If you
use it, say so in your report:

```bash
flate test all --path kube/clusters/artemis --allow-missing-secrets
```

## Diff Against the Live Cluster

```bash
mise run //kube/clusters/artemis:diff-ks <namespace> <ks-name>
```

This task is read-only. It renders locally with `flate`, then runs `kubectl diff --server-side`.
That is a server-side dry-run apply. The API server applies its own defaults before it compares, so
defaulted fields never show up as drift. A hand-made comparison of render and live cannot avoid
that. `dyff` renders the output, so a change shows as a field path, not a line number.

Exit codes: 0 means no differences. 1 means differences found _or_ a failed render. Read the output
to tell the two apart. The code does not. Drift ends on `WARN Differences found`. A bad ks name ends
on `flate error:`.

Run this check _before_ `suspend-ks` + `apply-ks`, to see what a change really moves. It is not the
same as `flate diff` below. This check compares local against the cluster. `flate diff` compares
local against `main`.

## Diff Against Main (changed-only)

```bash
git worktree add --detach /tmp/artemis-baseline main
flate diff ks --path kube/clusters/artemis --path-orig /tmp/artemis-baseline/kube/clusters/artemis
git worktree remove /tmp/artemis-baseline
```

Changed-only mode reconciles only the subtree that a change touches. It is fast, also on large
repos.

## List All Kustomizations

```bash
flate get ks --path kube/clusters/artemis
```

## Build a Specific HelmRelease

```bash
flate build hr --namespace <namespace> --output yaml <helmrelease-name>
```

## Validate Workflow (pre-commit checklist)

1. Render the changed kustomization: `mise run //kube/clusters/artemis:render-ks <ns> <ks>`.
2. Read the output, and look for changes that you did not expect.
3. See what the change really moves in the cluster: `mise run //kube/clusters/artemis:diff-ks <ns> <ks>`.
4. Run the full suite: `flate test all --path kube/clusters/artemis`. If a failure names a Secret
   that exists only in the live cluster, use the fallback in § Full Test Suite.
5. If the tests pass, continue with `.agents/skills/modules/test-and-commit.md`. The sequence is in
   `.agents/instructions/commit-style.md` § The sequence. That file wins.

## Notes

- flate handles ExternalSecrets. If an ExternalSecret declares the Secret, flate marks the Secret
  `Ready / "skipped"` and does not fail. In most cases you do not need `--allow-missing-secrets`.
- This cluster has no SOPS ciphertext. All secrets come from 1Password ExternalSecrets, so you never
  need to decrypt offline.
- OCI sources (app-template, and others) need network access to pull charts. Run with the network
  available.

---
name: review-app
description: Audit an existing app's manifests against this repo's conventions — security context, image pinning, storage, routes, probes, secrets wiring — and report what deviates. Use for "review X deployment", "audit X manifests", "check X against conventions", or "lint X app". Scoped to the Frostlink cluster.
---

# Skill: Review App Deployment

Audit an existing app's manifests against this repo's conventions and report (then optionally fix) any violations.

Read `.agents/instructions/cluster-conventions.md` and `yaml-conventions.md` first; open the `flux-patterns.md`, `networking.md` or `storage.md` reference if the app has dependencies, a route or persistence.

---

## Step 1 — Identify the App

Confirm before proceeding:

- **App name** (e.g. `gotosocial`)
- **Namespace** (e.g. `fediverse`)
- **Fix mode**: report-only (default) or apply fixes in place?

Derive the root path: `kubernetes/apps/<namespace>/<app>/`

---

## Step 2 — Read All Manifests

```bash
find kubernetes/apps/<namespace>/<app> -type f | sort
cat kubernetes/apps/<namespace>/kustomization.yaml
cat kubernetes/apps/<namespace>/<app>/ks.yaml
cat kubernetes/apps/<namespace>/<app>/app/kustomization.yaml
cat kubernetes/apps/<namespace>/<app>/app/ocirepository.yaml
cat kubernetes/apps/<namespace>/<app>/app/helmrelease.yaml
# only for the exceptions in cluster-conventions.md § Secrets:
cat kubernetes/apps/<namespace>/<app>/app/externalsecret.yaml
```

Read the files before evaluating — do not guess at their contents.

---

## Step 3 — Run the Checklists

Read each checklist module and work through every item. Mark each **PASS**, **FAIL**, or **N/A**.

| Checklist                             | Module                                                |
| ------------------------------------- | ----------------------------------------------------- |
| Directory structure                   | `.agents/skills/modules/checklists/directory.md`      |
| `ks.yaml`                             | `.agents/skills/modules/checklists/ks.md`             |
| `app/ocirepository.yaml`              | `.agents/skills/modules/checklists/ocirepository.md`  |
| `app/helmrelease.yaml`                | `.agents/skills/modules/checklists/helmrelease.md`    |
| ExternalSecret (inline or standalone) | `.agents/skills/modules/checklists/externalsecret.md` |
| Advisory (optimizations)              | `.agents/skills/modules/checklists/advisory.md`       |

Field order is checked once per file against `.agents/instructions/yaml-conventions.md` (plus `modules/sorting.md`) and reported as `[YAML]` items.

---

## Step 4 — Report Findings

Group findings by severity, one blank line between items, check IDs in bold, values in code:

- `### FAIL — must fix` (auto-fixable): e.g. **[H8]** `runAsNonRoot` is missing.
- `### WARN — convention drift` (auto-fixable): e.g. **[YAML]** `enabled` is not first in `probes.liveness`; **[H27a]** emptyDir `tmp` uses `globalMounts`.
- `### ADVISORY — recommendations` (never auto-fix): e.g. **[A2]** PVC without the `kopiur` component.
- `### PASS`: one line per area that is clean.

Start with `## Review: <app> (<namespace>)`. If nothing fails, say the app is convention-compliant,
still using the headed format.

---

## Step 5 — Fix Issues (if fix mode enabled)

For each FAIL or WARN, edit the file in place (never auto-fix ADVISORY items), using:

- `.agents/instructions/yaml-conventions.md` for all ordering rules
- `.agents/skills/modules/templates/ks.md` as the reference for ks.yaml corrections
- `.agents/skills/modules/templates/helmrelease.md` as the reference for HelmRelease corrections

Apply all fixes before showing a diff. Do not change values or behavior — only fix ordering, missing boilerplate, and convention violations.

After fixing, re-read the edited files and confirm no issues remain.

---

## Step 6 — Test and Commit (if fixes were applied)

Read `.agents/skills/modules/test-and-commit.md` and follow it.

If anything fails during apply, read `.agents/skills/modules/common-issues.md` for diagnostics.

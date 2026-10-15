---
name: deploy-app
description: Deploy a new app into the Flux cluster end to end — scaffold the ks.yaml and app/ manifests, wire the OCIRepository, HelmRelease, routes, storage, and any ExternalSecret, then test-apply before committing. Use for "deploy X", "add app X", "set up X in namespace Y", "create a new app", or "onboard X to the cluster". Scoped to the Frostlink cluster. For an app that already exists, use `review-app`.
---

# Skill: Deploy App

Deploy a new application to Frostlink following the canonical GitOps workflow.

Read `.agents/instructions/cluster-conventions.md` first; open `.agents/references/` `flux-patterns.md`, `networking.md` or `storage.md` as the app needs a dependency, a route or persistence (the `AGENTS.md` table says when).

---

## Step 1 — Gather Requirements

Confirm before proceeding:

- **App name** (e.g. `myapp`)
- **Namespace** — must exist or user confirms creating it
- **Chart**: default is app-template. Ask if different.
- **Route**: `external-gateway` (the only gateway on this cluster), or none
- **Hostname**: e.g. `myapp.frostlink.dev` (an HTTPRoute on `external-gateway` gets its DNS record automatically; a manual `DNSEndpoint` does not — `networking.md`)
- **Persistence**: PVC needed? If yes: size (e.g. `5Gi`) — storage class is `openebs-zfs`
- **Secrets**: 1Password ExternalSecret needed? If yes: 1Password item name

Read 1–2 existing apps in the same namespace to match local patterns before writing anything:

```bash
ls kubernetes/apps/<namespace>/
cat kubernetes/apps/<namespace>/<existing-app>/ks.yaml
cat kubernetes/apps/<namespace>/<existing-app>/app/helmrelease.yaml
```

---

## Step 2 — Find a Reference with Kubesearch

Invoke the `kubesearch` skill for the app name. Use the top result to fill in the remaining unknowns:

| What                   | Where it goes                                |
| ---------------------- | -------------------------------------------- |
| Image repository + tag | Step 3 (image pinning)                       |
| Container port         | `service.app.ports.http.port` in helmrelease |
| Mount paths            | `persistence` block in helmrelease           |
| App-specific env vars  | `containers.app.env` in helmrelease          |
| Secret env var names   | `values.externalSecrets` template fields     |

Adapt the reference to this cluster with `cluster-conventions.md` § Common Mistakes — Quick Reference, and § Database & Cache if it brings its own Postgres or Redis.

If kubesearch returns no results, fall back to the GitHub search in the kubesearch skill and proceed with what you find.

---

## Step 3 — Pin the Image Tag

Using the image repository identified in Step 2, read `.agents/skills/modules/image-pinning.md` and follow it.

---

## Step 4 — Create Directory Structure

Read `.agents/skills/modules/templates/directory.md` and create the layout.

**If the namespace doesn't exist yet**, create `kubernetes/apps/<namespace>/namespace.yaml` and
`kustomization.yaml` the way an existing namespace does (`kubernetes/apps/network/` is a good
model). Do not add PodSecurity labels; the namespace inherits `baseline` (a privileged one needs
the justification in `towonel.md` § Why its own namespace).

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
    name: _
    annotations:
        kustomize.toolkit.fluxcd.io/prune: disabled
```

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <namespace>
components:
    - ../../components/alerts
resources:
    - ./namespace.yaml
    - ./<app>/ks.yaml
```

The root Kustomization (`flux-system`) points at `./kubernetes/apps` and there is no top-level
`kustomization.yaml`, so a new namespace directory needs no further wiring.

---

## Step 5 — Write Files

Read the relevant template module for each file and write it:

| File                     | Template module                                                               |
| ------------------------ | ----------------------------------------------------------------------------- |
| `ks.yaml`                | `.agents/skills/modules/templates/ks.md`                                      |
| `app/kustomization.yaml` | `.agents/skills/modules/templates/kustomization.md`                           |
| `app/ocirepository.yaml` | `.agents/skills/modules/templates/ocirepository.md`                           |
| `app/helmrelease.yaml`   | `.agents/skills/modules/templates/helmrelease.md`                             |
| inline `externalSecrets` | `.agents/skills/modules/templates/externalsecret.md` (only if secrets needed) |

Field order: `.agents/instructions/yaml-conventions.md` (`modules/sorting.md` adds two rules).

---

## Step 6 — Add to Namespace Kustomization

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources.

---

## Step 7 — Verify Files

Confirm the layout matches `templates/directory.md`, then validate that the kustomization renders:

```bash
just kube render-local-ks <namespace> <ks-name>
```

This catches schema errors, missing substitution variables and malformed YAML before anything touches the cluster (`flux-validate` has the full suite). Fix errors before Step 8.

---

## Step 8 — Test and Commit

Read `.agents/skills/modules/test-and-commit.md` and follow it.

If anything fails, read `.agents/skills/modules/common-issues.md` for diagnostics.

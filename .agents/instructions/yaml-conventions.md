---
paths:
    - "kubernetes/**/*.yaml"
    - "kubernetes/**/*.yml"
---

# YAML Conventions — Frostlink

All Kubernetes manifests follow these field ordering rules. Default is alphabetical at every level unless overridden below.

## Top-Level Kubernetes Resources

```
apiVersion → kind → metadata → spec
```

## metadata

```
name → namespace → annotations → labels
```

## HelmRelease (app-template)

`spec` level:

```
chartRef → interval → dependsOn → install → upgrade → values
```

`spec.values` level:

```
defaultPodOptions   ← always first
controllers         ← alphabetical after defaultPodOptions
persistence
route
service
serviceAccount
```

## Controllers

```
type → annotations → labels → <controller-specific fields> → pod → initContainers → containers
```

`enabled` field is always first within any section that has it.

## Containers

```
image               ← always first
<rest alphabetical>
```

Resources: `requests` before `limits`.

## Services

```
type → annotations → labels → <alphabetical> → ports → globalMounts/advancedMounts
```

## Persistence

```
type → annotations → labels → <alphabetical> → globalMounts/advancedMounts   ← always last
```

## ks.yaml (Flux Kustomization)

```
apiVersion → kind → metadata → spec:
  targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild
```

## General Rules

- Never sort YAML within string values (e.g. config file contents inside ConfigMaps)
- `enabled: true/false` is always the first field in any section
- Alphabetical applies recursively at every nesting level unless a specific order is defined above

## No Comments in Manifests

**Manifests carry configuration, not prose.** Do not add explanatory comments to anything
under `kubernetes/`, or to the repo-root `.renovaterc.json5` — no rationale, no incident
history, no "keep this ordered" warnings, no commented-out alternatives. Rationale belongs in
`.agents/references/<topic>.md`, where it is searchable, reviewable, and does not have to be
re-read on every manifest edit.

Three exceptions, all machine-oriented:

| Allowed                                          | Why                                        |
| ------------------------------------------------ | ------------------------------------------ |
| `# yaml-language-server: $schema=…`              | injected and maintained by the schema hook |
| YAML anchor markers where the anchor is subtle   | reading aid for `&name` / `*name` pairs    |
| Renovate directives (`# renovate: datasource=…`) | consumed by Renovate                       |

When a value is non-obvious enough to feel like it needs a comment, write it up in the matching
reference doc instead. Example: the kopiur R2 credential key warning lives in
`.agents/references/storage.md` § The R2 credential key is unrecoverable if repointed, not in the
ExternalSecret.

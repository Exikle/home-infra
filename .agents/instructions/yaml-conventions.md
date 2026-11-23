---
paths:
    - "kube/base/**/*.yaml"
    - "kube/components/**/*.yaml"
    - "kube/clusters/*/apps/**/*.yaml"
    - "kube/clusters/*/components/**/*.yaml"
---

# YAML Conventions — home-infra

This file says how manifests in this repo are shaped, ordered, and kept clean. The rules apply to
both clusters (`kube/clusters/artemis/` and `kube/clusters/frostlink/`) and to the shared
`kube/base/` and `kube/components/` folders. Frostlink uses the same field ordering and has no
YAML rule of its own. § What the tooling does for you says which hook covers which folders.

## What the tooling does for you

`hk.pkl` runs these steps at commit. Each step covers the folders in its last column.

| Step                                               | Fixes automatically at commit                                          | Does NOT fix                                              | Folders it covers                                                      |
| -------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------- |
| oxfmt                                              | indentation, flow-list spacing, trailing whitespace, final newline     | quoting, anchors                                          | every `*.yaml` file in the repo                                        |
| `hooks/k8s_yaml_schema.py` (`k8s-schema`)          | the `# yaml-language-server: $schema=` modeline                        | non-k8s YAML, core-API (`v1`) kinds                       | `kube/base/`, `kube/components/`, `kube/clusters/*/{apps,components}/` |
| `scripts/normalize-yaml-order.py` (`yaml-order`)   | every order in § Semantic Orders by Kind, and the `resources` list     | which fields exist. It reorders, it never adds or deletes | `kube/base/`, `kube/components/`, `kube/clusters/*/{apps,components}/` |
| `scripts/check-yaml-comments.py` (`yaml-comments`) | nothing. It fails the commit on a comment (§ No Comments in Manifests) | everything else                                           | `kube/base/`, `kube/components/`, `kube/clusters/*/{apps,components}/` |

No hook checks that a Kustomization declares `wait`.

oxfmt reformats YAML inside markdown fences to 4-space indentation, which is its own style.
Manifests use 2-space indentation. That is not drift. You cannot fix it in the doc, because the
hook rewrites it back. Copy structure out of a template, never indentation.

## Document Shape

Every Kubernetes manifest document has this shape:

```yaml
---
# yaml-language-server: $schema=<injected by hook — leave in place, hook keeps it current>
apiVersion: ...
kind: ...
metadata: name → namespace → annotations → labels
spec: ...
```

- Top-level key order is always `apiVersion → kind → metadata → spec`.
- `metadata` order is always `name → namespace → annotations → labels`.
- Always start each document with `---`, including the first document in the file.
- In a multi-document file (for example `ks.yaml` with several Kustomizations), separate the
  documents with a bare `---`.
- The schema domain is `k8s-schemas.home-operations.com`. app-template HelmReleases get the
  bjw-s schema URL. The hook resolves this from the sidecar `ocirepository.yaml`. Do not hand-edit
  it.

## The One Rule

Order keys alphabetically at every nesting level, except where a semantic order is defined below.
A semantic order exists where reading order matters more than lookup order: identity first,
routing and configuration in the middle, mounts last.

Two qualifiers apply to "every nesting level":

- Siblings under a map of named items are not ordered relative to each other. Within
  `persistence`, `service`, `route`, `configMaps`, `controllers` and similar maps, the named
  entries (`persistence.config`, `persistence.media`, …) can appear in any order. Only the keys
  _inside_ each named entry follow the rules below. Do not reshuffle named entries to alphabetize
  them.
- A YAML anchor must appear before any alias that references it. If alphabetical order puts
  `&name` after its first `*name`, the anchor wins and moves to the top of its section. Treat it
  exactly like `enabled`. Define anchors at first natural use (`port: &port 8000`).

> The home-operations upstream repos alphabetize the `ks.yaml` spec too. This repo deliberately
> keeps a semantic order there (identity → source → timing → wiring). Do not "fix" it to match
> upstream.

## Semantic Orders by Kind

### ks.yaml (Flux Kustomization) — `spec`

```text
targetNamespace → commonMetadata → path → prune → sourceRef
→ interval → retryInterval → timeout
→ dependsOn → components → postBuild
→ wait → healthChecks
```

`wait` goes last (before `healthChecks`). Every Kustomization document must declare it, on both
clusters. No hook checks that `wait` is present. § No Restating Defaults gives the reason that the
redundant `wait: false` stays. In the folders that it covers, the normalizer enforces this order.
So this list is canonical, not aspirational.

### HelmRelease — `spec`

```text
chartRef → interval → dependsOn → install → upgrade → values → postRenderers
```

### HelmRelease — `spec.values` (app-template)

`defaultPodOptions` is always first. The rest is strictly alphabetical:

```text
defaultPodOptions → configMaps → controllers → persistence → podDisruptionBudget
→ route → service → serviceAccount → serviceMonitor
```

For a chart that is not app-template, follow the values structure of the chart. Never reorder a
vendored or upstream values layout only to alphabetize it.

### Controller entries (`controllers.<name>`)

```text
enabled → type → annotations → labels → <controller fields: replicas, strategy, …>
→ pod → initContainers → containers
```

### Container entries (`containers.<name>`)

`image` is always first. The rest is alphabetical:

```text
image → args → command → env → envFrom → probes → resources → securityContext
```

Resources: `requests` before `limits`.

### Init containers (`initContainers.<name>`)

These have the same shape as `containers.<name>`: `image` first, the rest alphabetical.
`initContainers` is second-to-last in a controller entry, immediately before `containers`.

### Persistence entries (`persistence.<name>`)

Identity is first. Mounts are always last:

```text
type | existingClaim → annotations → labels → <alphabetical: defaultMode, identifier, name, path, server, …>
→ globalMounts | advancedMounts
```

If both are present, `globalMounts` is second-to-last and `advancedMounts` is last.

### Service entries (`service.<name>`)

```text
type → annotations → labels → <alphabetical: controller, externalTrafficPolicy, …> → ports
```

### Route entries (`route.<name>`)

Plain alphabetical: `annotations → hostnames → parentRefs → rules`

### OCIRepository / ExternalSecret — `spec`

Plain alphabetical. These are the canonical shapes:

- OCIRepository: `interval → layerSelector → ref → url`
- ExternalSecret: `dataFrom → refreshInterval → secretStoreRef → target`

### kustomization.yaml (kustomize)

```text
apiVersion → kind → namespace → components → resources → <alphabetical rest>
```

- Sort the `resources` list. The normalizer puts `./namespace.yaml` first, then sorts the rest
  in plain ASCII order. So `../` entries come before the other `./` entries.
- For a new app, insert `- ./<app>/ks.yaml` in alphabetical position.

## General Rules

- `enabled: true/false` is always the first field in any section that has it.
- Never sort inside string values. Configuration file payloads in ConfigMaps and Secrets keep the
  natural order of their application.
- Never reorder keys in vendored content (upstream chart values, dashboard JSON, alert rules).
- Quote env values that YAML otherwise coerces: `"true"`, `"1"`, `"60"`.
- Put one kind in each file (the helmrelease / ocirepository split). The filename is the
  lowercased kind. Several objects of the same kind in one folder share that file, as separate
  documents (for example both ArtifactGenerators in `kube/base/flux-system/artifactgenerator.yaml`).
  There are two exceptions. `ks.yaml` holds all of the Flux Kustomizations of an app. The inline
  `externalSecrets` of app-template live in `helmrelease.yaml`.

## No Restating Defaults

A manifest states what it changes. If the value of a field is already the default of the chart,
the Kubernetes API, or the CRD, the field does not belong in the manifest. It is noise that reads
like a decision.

Prove the default before you delete it, and cite where. Cite the `values.yaml` of the chart, the
`+kubebuilder:default` of the CRD, or the API reference, never memory. A survey from memory once
got `replicas` backwards, and the field was nearly deleted on a false premise.

### Deliberate exceptions — do not strip these

| Field                          | Why it stays                                                                                                                                               |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wait` on a Flux Kustomization | It gates `dependsOn` ordering, so a reader needs the answer without knowing the default of Flux. Every Kustomization document must declare it (§ ks.yaml). |
| `enabled: true`                | It is mandated as the first field of any section that has one. See § General Rules.                                                                        |

### Proven NOT default — leave them alone

These fields look strippable, but they are not. Each one was checked against source. The note is
here so that no one re-derives it and gets it wrong a second time.

| Field                                      | Actual default                                                                                                                                                                                                                      |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prune` (Flux Kustomization)               | `+required` in the CRD. No default exists at all                                                                                                                                                                                    |
| `install`/`upgrade.remediation.retries: 3` | The default of Flux is `0`                                                                                                                                                                                                          |
| `upgrade.cleanupOnFail: true`              | The default of Flux is `false`                                                                                                                                                                                                      |
| `strategy: RollingUpdate` (app-template)   | The chart default is `Recreate`. So `RollingUpdate` is the override, and `Recreate` is the redundant one                                                                                                                            |
| `replicas: 1` (app-template)               | The chart default is `null`, not `1`. With `null`, the field is omitted, so an HPA can own it and Flux does not fight a manual scale. An explicit `1` makes Flux enforce `1`. That is different behaviour, not a redundant default. |
| `layerSelector` (OCIRepository)            | Unverified. A Helm OCI artifact can carry more than one layer, so "first layer found" is not provably equivalent. Do not delete it without a test.                                                                                  |

A resource templated inside a Flux `ResourceSet` is invisible to any script that iterates over
top-level documents. For this reason, a script missed
`components/postgres/tenants/resourceset.yaml`, and someone had to fix it by hand. Read
ResourceSet bodies when you sweep for a field.

## Where the rules live

This file is the single authority for ordering. Cite this file. Do not restate it.
`.agents/skills/modules/checklists/yaml-sorting.md` is the review-time checklist form. It checks
the rules. It does not define them.

## No Comments in Manifests

Manifests carry configuration, not prose. Do not add explanatory comments to anything under
`kube/`, or to the repo-root `.renovaterc.json5`. That means no rationale, no incident
history, no "keep this ordered" warnings, and no commented-out alternatives. Rationale belongs in
`.agents/references/<topic>.md`. There it is searchable and reviewable, and no one must re-read it
on every manifest edit.

The `yaml-comments` hook checks `kube/base/`, `kube/components/` and both clusters' `apps/`
and `components/` folders. It skips `resources/` folders. To check by hand, run
`python3 scripts/check-yaml-comments.py`.

There are three exceptions, all machine-oriented:

| Allowed                                          | Why                                        |
| ------------------------------------------------ | ------------------------------------------ |
| `# yaml-language-server: $schema=…`              | injected and maintained by the schema hook |
| Anchor markers (`# &name`, `# *name …`)          | reading aid for `&name` / `*name` pairs    |
| Renovate directives (`# renovate: datasource=…`) | consumed by Renovate                       |

An anchor marker is a comment that starts with `&name` or `*name`. The hook allows all three
exceptions.

### Shell scripts embedded in a manifest are code, not manifest

A `script:` or `command:` block scalar (init containers, CronJob scripts) is a program, and a
program can carry code comments. There, the rule is one terse line, not a paragraph. Say what the
next few lines do, and put the reasoning in the reference doc. A multi-line rationale essay inside
an init script is the same violation as one in the manifest body.

If a value seems to need a comment, write it up in the matching reference doc instead. If the
constraint is dangerous to violate, reviewers then cite the doc. For example, the ordering of the
CoreDNS `template` plugin is load-bearing, and its rationale runs about 40 lines. It lives in
`.agents/references/networking.md` § CoreDNS, and the manifest itself is bare. Another
example: the kopiur R2 credential key warning lives in `.agents/references/openebs-zfs.md`
(Frostlink), not in the ExternalSecret.

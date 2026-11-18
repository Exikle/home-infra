# Checklist: YAML Sorting

The rules are in `.agents/instructions/yaml-conventions.md`, which wins. Mark each item PASS, FAIL,
or N/A.

The `yaml-order` hook enforces these orders at commit on both clusters. To check before a commit,
run `hooks/python scripts/normalize-yaml-order.py --check <app dir>`. It exits 1 and names each
file that is out of order.

## All files

| #   | Check                                                                                                                                                    | Result |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| Y1  | Top-level order: `apiVersion → kind → metadata → spec`                                                                                                   |        |
| Y2  | `metadata` order: `name → namespace → annotations → labels` (namespace omitted on app manifests, because the Kustomization `targetNamespace` injects it) |        |
| Y3  | `enabled` is the first field in every section that has it                                                                                                |        |
| Y4  | All other fields at every nesting level are alphabetical unless a specific rule applies                                                                  |        |
| Y5  | YAML anchors (`&foo`) appear before any alias (`*foo`) that references them                                                                              |        |
| Y6  | YAML inside string values (for example ConfigMap data keys) is not sorted                                                                                |        |

## HelmRelease `spec`

| #   | Check                                                                                                                        | Result |
| --- | ---------------------------------------------------------------------------------------------------------------------------- | ------ |
| Y7  | `spec` order: `chartRef → interval → dependsOn → install → upgrade → values → postRenderers`                                 |        |
| Y8  | `spec.values` order: `defaultPodOptions` first (if present), then alphabetical                                               |        |
| Y9  | Siblings within `persistence`, `service`, `route`, `configMaps` do not have to be sorted. Only the keys within each item are |        |

## Controllers

| #   | Check                                                                                                                      | Result |
| --- | -------------------------------------------------------------------------------------------------------------------------- | ------ |
| Y10 | `controllers.*` order: `enabled → type → annotations → labels → <controller-specific> → pod → initContainers → containers` |        |

## Containers / initContainers

| #   | Check                                                   | Result |
| --- | ------------------------------------------------------- | ------ |
| Y11 | Container block order: `image` first, then alphabetical |        |
| Y12 | `resources` order: `requests` before `limits`           |        |

## Services

| #   | Check                                                                                         | Result |
| --- | --------------------------------------------------------------------------------------------- | ------ |
| Y13 | `service.*` item order: `type → annotations → labels → <alphabetical> → ports` (`ports` last) |        |

## Persistence

| #   | Check                                                                                                                    | Result |
| --- | ------------------------------------------------------------------------------------------------------------------------ | ------ |
| Y14 | `persistence.*` item order: `type → annotations → labels → <alphabetical> → globalMounts → advancedMounts` (mounts last) |        |

# Module: YAML Sorting

The ordering rules are owned by `.agents/instructions/yaml-conventions.md`. Two rules it does not
carry:

- A YAML anchor (`&foo`) must appear before any alias (`*foo`). If alphabetical order would put the
  anchor after its first alias, move the anchor up, treating it like `enabled` (always first).
- Sibling items under `persistence`, `service`, `route` and `configMaps` need not be sorted against
  each other; only the keys inside each item are.

`ks.yaml` details (`wait`, `healthChecks`) are in `templates/ks.md`.

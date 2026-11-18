# Checklist: YAML Sorting

The rules are in `.agents/instructions/yaml-conventions.md`, which wins. Mark each item PASS, FAIL,
or N/A.

| #          | Check                                                                                                                                                                                               | Result |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| Normalizer | Key order. The `yaml-order` hook enforces it at commit on both clusters. Run `hooks/python scripts/normalize-yaml-order.py --check <app dir>`. It exits 1 and names each file that is out of order. |        |
| Y5         | YAML anchors (`&foo`) appear before any alias (`*foo`) that references them                                                                                                                         |        |
| Y6         | YAML inside string values (for example ConfigMap data keys) is not sorted                                                                                                                           |        |

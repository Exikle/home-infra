# Checklist: app/ocirepository.yaml

Mark each item PASS, FAIL, or N/A.

| #   | Check                                                                                                                                                                                                                                     | Result |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| O1  | Schema comment present: `# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json`                                                                                          |        |
| O2  | `apiVersion: source.toolkit.fluxcd.io/v1` (not `v1beta2`)                                                                                                                                                                                 |        |
| O3  | `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (`bjw-s-labs`, not `bjw-s`)                                                                                                                                                             |        |
| O4  | `layerSelector.mediaType` and `layerSelector.operation: copy` both present                                                                                                                                                                |        |
| O5  | `ref.tag` equals the app-template tag that most apps in the same cluster use. Recover it with the command in `templates/ocirepository.md` § Values that drift. A tag that differs from that tag is a FAIL, unless the app lags on purpose |        |
| O6  | `name` matches the app name and is not shared with another app                                                                                                                                                                            |        |
| O7  | Metadata has `name` only and no `namespace`. The `targetNamespace` of the Kustomization injects it                                                                                                                                        |        |
| O8  | Field order: top level `apiVersion → kind → metadata → spec`, and `spec` alphabetical (`interval → layerSelector → ref → url`). `hooks/python scripts/normalize-yaml-order.py --check <app dir>` exits 0                                  |        |

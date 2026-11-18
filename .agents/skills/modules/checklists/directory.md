# Checklist: Directory Structure

Mark each item PASS, FAIL, or N/A. `<cluster>` is `artemis` or `frostlink`.

| #   | Check                                                                                                                                                                                                                                      | Result |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ |
| S1  | `ks.yaml` exists at `kube/clusters/<cluster>/apps/<namespace>/<app>/ks.yaml`                                                                                                                                                               |        |
| S2  | `app/kustomization.yaml` exists                                                                                                                                                                                                            |        |
| S3  | `app/ocirepository.yaml` exists                                                                                                                                                                                                            |        |
| S4  | `app/helmrelease.yaml` exists                                                                                                                                                                                                              |        |
| S5  | `<app>/ks.yaml` is listed in the resources of `kube/clusters/<cluster>/apps/<namespace>/kustomization.yaml`                                                                                                                                |        |
| S6  | No standalone `HTTPRoute` files. Routes are defined in the HelmRelease values                                                                                                                                                              |        |
| S7  | Artemis only. If the app uses `kopiur/backup`, the namespace `kustomization.yaml` carries `../../components/kopiur/secret`. If the app uses `postgres/app`, the namespace `kustomization.yaml` carries `../../components/postgres/tenants` |        |

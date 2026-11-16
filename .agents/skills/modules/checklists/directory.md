# Checklist: Directory Structure

Mark each item PASS, FAIL, or N/A.

Frostlink: the same checks apply with `kube/clusters/frostlink/apps/` in place of the Artemis path.

| #   | Check                                                                                              | Result |
| --- | -------------------------------------------------------------------------------------------------- | ------ |
| S1  | `ks.yaml` exists at `kube/clusters/artemis/apps/<namespace>/<app>/ks.yaml`                         |        |
| S2  | `app/kustomization.yaml` exists                                                                    |        |
| S3  | `app/ocirepository.yaml` exists                                                                    |        |
| S4  | `app/helmrelease.yaml` exists                                                                      |        |
| S5  | `<app>/ks.yaml` is listed in `kube/clusters/artemis/apps/<namespace>/kustomization.yaml` resources |        |
| S6  | No standalone `HTTPRoute` files. Routes are defined in helmrelease values                          |        |
| S7  | No `.sops.yaml` or age-encrypted files present                                                     |        |

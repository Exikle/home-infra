# Checklist: ks.yaml

Mark each item **PASS**, **FAIL**, or **N/A**.

Authoritative spec field order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild → wait`

| #   | Check                                                                                                                                                                                          | Result |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| K1  | Schema comment present: `# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json`                                            |        |
| K2  | `spec` fields follow canonical order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval → [retryInterval → timeout →] [dependsOn →] [components →] [postBuild →] [wait]` |        |
| K3  | `commonMetadata.labels` includes `app.kubernetes.io/name: <app>`                                                                                                                               |        |
| K4  | `path: ./kubernetes/apps/<namespace>/<app>/app`                                                                                                                                                |        |
| K5  | `prune: true` (or intentionally `false` with a documented reason)                                                                                                                              |        |
| K6  | `sourceRef.kind: OCIRepository`, `name: flux-system`, `namespace: flux-system`                                                                                                                 |        |
| K7  | `interval: 1h` (or `30m` for kube-system bootstrap apps)                                                                                                                                       |        |
| K8  | If Kopiur used: `dependsOn` includes `kopiur-repository` (namespace: `kopiur-system`)                                                                                                          |        |
| K9  | If ExternalSecret used: `dependsOn` includes `onepassword-connect` (namespace: `external-secrets`)                                                                                             |        |
| K10 | If Kopiur used: `components` includes `../../../../components/kopiur`                                                                                                                          |        |
| K11 | If Kopiur used: `postBuild.substitute` sets `KOPIUR_APP` and `KOPIUR_CAPACITY`                                                                                                                 |        |
| K12 | Every cross-namespace `dependsOn` entry has an explicit `namespace:` field                                                                                                                     |        |

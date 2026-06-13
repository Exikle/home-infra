# Cluster Conventions — Frostlink

## App Directory Structure (canonical)

```text
kubernetes/apps/<namespace>/<app>/
├── ks.yaml                  # Flux Kustomization — dependsOn, PVC size
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml   # standalone OCIRepository — every app gets its own
    ├── helmrelease.yaml     # HTTPRoutes defined in values here, not separate files
    └── externalsecret.yaml  # only if secrets needed
```

Add `- ./<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml` resources.

## Helm / app-template v5

- Chart: `oci://ghcr.io/bjw-s-labs/helm/app-template` tag `5.0.1` (note: `-labs`, not `-bjw-s`)
- Every app gets its own standalone `OCIRepository` — never share or reuse one
- `chartRef` in HelmRelease: `kind: OCIRepository, name: <app>`
- OCIRepository API version: `source.toolkit.fluxcd.io/v1` (not `v1beta2`)
- Reloader: `reloader.stakater.com/auto: "true"` annotation on controller
- Default security context: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch`
- Container security: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: {drop: ["ALL"]}`
- Routes: defined inline under `route.app:` in helmrelease values — NOT as standalone HTTPRoute files

## Secrets

- SOPS is not used — never suggest age encryption or `sops --encrypt`
- All secrets: 1Password ExternalSecrets with `ClusterSecretStore: onepassword-connect`
- ExternalSecret API version: `external-secrets.io/v1`

## Storage

- **No Rook-Ceph** (single node)
- Primary storage class: `local-path`
- PVC: `existingClaim: <app>` when using VolSync component (if/when added)

## Single-Node Notes

- `allowSchedulingOnControlPlanes: true` — set in `talos/patches/controlplane.yaml`
- No nodeSelector needed for any workload — the single node runs everything

## Common Mistakes — Quick Reference

| Pattern                  | Correct                          | Wrong                                   |
| ------------------------ | -------------------------------- | --------------------------------------- |
| Secret store name        | `onepassword-connect`            | `onepassword`, `1password-connect`      |
| Gateway (internal)       | `internal-gateway`               | `internal`, `envoy-internal`            |
| Gateway (external)       | `external-gateway`               | `external`, `envoy-external`            |
| Gateway namespace        | `network`                        | `default`, `networking`                 |
| OCIRepository API        | `source.toolkit.fluxcd.io/v1`    | `v1beta2`                               |
| ExternalSecret API       | `external-secrets.io/v1`         | `v1beta1`                               |
| Flux Kustomization API   | `kustomize.toolkit.fluxcd.io/v1` | `v1beta2`                               |
| Container image tag      | `v1.0.0@sha256:abc...`           | `latest`, bare `v1.0.0`                 |
| OCIRepository chart tag  | bare version `2.5.0` (no SHA)    | SHA-pinned — not used for Helm charts   |
| Timezone                 | never set `TZ` — k8tz handles it | `TZ: America/Toronto`                   |
| HTTPRoute location       | inline in helmrelease values     | standalone HTTPRoute file               |
| Cluster traffic          | `<app>.<ns>.svc.cluster.local`   | external hostname                       |
| OCIRepository scope      | one per app                      | shared across apps                      |
| Storage class            | `local-path`                     | `ceph-block`, `standard`                |

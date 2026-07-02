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

## Database & Cache

Reversed 2026-07-01: apps no longer default to SQLite or an app-specific/sidecar database.
Frostlink runs one shared CNPG Postgres cluster and one shared Dragonfly instance; apps attach
to them instead of provisioning their own.

- **Postgres**: shared `Cluster/postgres` + `Pooler/pooler-rw` in the `database` namespace
  (CNPG, `cnpg-system` namespace). No app runs its own sidecar `postgres:` container or an
  app-specific CNPG `Cluster` anymore.
- **Onboarding a new app**: add the `kubernetes/components/postgres/cert` Flux Component to the
  app's `ks.yaml` (`dependsOn: postgres-ca` in `cert-manager`). It provisions a `Database` CR
  (via a nested `${APP}-db` Kustomization), a client `Certificate` (CN = app name, issued by
  `postgres-client-ca`), and a `ConfigMap` with the full mTLS connection string — apps read the
  DSN from that ConfigMap, never a literal Secret (auth is cert-based, there's no password).
  `ksgate` (`kube-system` namespace) gates the app pod until the `Database` CR is Ready.
- **Never connect directly to the `Cluster`** — always go through `pooler-rw.database.svc:5432`.
- **Cache/queue**: shared `Dragonfly` CR in the `database` namespace (`dragonfly-operator`,
  `dragonfly-system` namespace). No app runs its own sidecar Redis/Valkey.
- **Backups**: the shared Postgres cluster backs up via the `barman-cloud` CNPG plugin to
  `s3://frostlink-kopiur/barman/` — same R2 bucket Kopiur uses for PVC snapshots, isolated by
  the `barman/` prefix (Kopia writes to the bucket root with no prefix, so there's no collision).

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
| App database             | shared `postgres/cert` component | sidecar postgres, SQLite, app-specific CNPG |
| App cache/queue          | shared Dragonfly (`database` ns) | sidecar Redis/Valkey                    |

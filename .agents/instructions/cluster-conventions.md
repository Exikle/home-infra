---
paths:
    - "kube/base/**"
    - "kube/components/**"
    - "kube/clusters/*/apps/**"
    - "kube/clusters/*/overlays/**"
    - "kube/clusters/*/components/**"
---

# Cluster Conventions — home-infra

These rules cover both clusters. An item that holds for one cluster only carries a label. A
section without a label is shared. The differences of Frostlink are in `frostlink.md`. That file
loads on `kube/clusters/frostlink/{apps,overlays,components}/**`, and it wins there.

## App Directory Structure

An app that one cluster runs is one directory under `kube/clusters/<cluster>/apps/<namespace>/`.
A shared app is one directory under `kube/base/<namespace>/` (below). The directory holds
exactly one `ks.yaml`. That file can contain several Flux Kustomization documents, one per
sub-directory. There is never more than one `ks.yaml` per app directory. There is never a
grouping directory between a namespace and its apps. Add `- ./<app>/ks.yaml` to the namespace
`kustomization.yaml` in alphabetical position.

An app that both clusters run lives once, complete, in `kube/base/<ns>/<app>/`, with its
`ks.yaml`. The menu `kube/base/<ns>/kustomization.yaml` lists it. If a cluster runs it
differently, only the differences go in `kube/clusters/<cluster>/overlays/<ns>/<app>/`. Its
`spec.path` names a real folder: `./kube/base/<ns>/<app>/...` when no cluster has differences,
else `./kube/clusters/${CLUSTER}/overlays/<ns>/<app>/...`. A
shared app never also has a folder in a cluster's `apps/`. There is no `extras/` folder.
`app-structure.md` § Shared apps (`kube/base/`) has the file shape, and it wins.

Kustomization names are `<app>-<component>`. When the components are one product,
`commonMetadata.labels.app.kubernetes.io/name` is the app, not the component. Label the component
only where the components are separate deployables. An example is `vm-operator` and `vm-single`
in `observability/victoria`. Those names do not follow `<app>-<component>`.

An operator that serves the whole cluster gets its own `*-system` namespace. An operator whose
operand lives in the same namespace is a sub-directory of the app directory of the operand, never
a sibling top-level app.

Non-standard resource types: put one kind in each file. The filename is the lowercased kind, and
several objects of that kind share the file (`yaml-conventions.md` § General Rules wins).
Keep the files flat in the leaf directory, and list them alphabetically. There is no `rbac/`,
`monitoring/` or `network/` sub-directory. An app-template app defines its `HTTPRoute` inline,
under `route.app:` in its values. An app with no app-template HelmRelease uses a standalone
`httproute.yaml` (for example `flux-webhook` and `cortex/agentgateway`).

The five canonical shapes are single, multi-component, operator/operand, CR collection, and fleet.
Their directory trees and tradeoffs are in `.agents/references/app-structure.md`.

## Helm / app-template

- Chart: `oci://ghcr.io/bjw-s-labs/helm/app-template` (note: `-labs`, not `-bjw-s`). Renovate
  bumps the tag fleet-wide. Recover it with the command in `AGENTS.md` § Make a version fact a
  command.
- Every app gets its own standalone `OCIRepository`. Never share or reuse one.
- `chartRef` in HelmRelease: `kind: OCIRepository, name: <app>`.
- OCIRepository API version: `source.toolkit.fluxcd.io/v1` (not `v1beta2`).
- Reloader: the `reloader.stakater.com/auto: "true"` annotation on the controller.
- Default security context: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`,
  `fsGroupChangePolicy: OnRootMismatch`.
- Container security: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
  `capabilities: {drop: ["ALL"]}`.
- (Artemis) PVC: `existingClaim: <app>` when the app uses the kopiur component.
- (Artemis) NFS media mount: the server, path and mount point are in
  `.agents/references/storage.md`.

## Secrets

- All secrets: a 1Password ExternalSecret with `ClusterSecretStore: onepassword-connect`
  (`AGENTS.md` rule 3 wins on SOPS and the store name).
- ExternalSecret API version: `external-secrets.io/v1`.
- app-template apps define their ExternalSecret inline, under `values.externalSecrets.<id>`
  in `helmrelease.yaml`. A standalone `externalsecret.yaml` is only for a chart that is not
  app-template, or for a Secret that something reads before the HelmRelease exists (for example
  `postBuild.substituteFrom`).
- `dataFrom.extract.key: <1password-item-name>` pulls all fields from the item.
- Template field names must exactly match the 1Password field names. A mismatch gives an empty
  secret with no error.

## Deployment Philosophy (Artemis)

Frostlink also uses a shared data layer, but its wiring differs. See `frostlink.md` § Database
and cache.

Use the shared data layer first. The shared CNPG cluster and the shared Dragonfly in the
`database` namespace are the default for new apps.

| Need                  | Preferred approach                                                                              |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| Relational DB         | Shared CNPG cluster via `postgres-rw` (add `components/postgres/app` + an `APP` substitution)   |
| Redis / queue / cache | Shared Dragonfly at `dragonfly.database.svc.cluster.local:6379`, no auth, no persistence        |
| Multi-component apps  | Split into separate kustomizations (for example Immich: app / microservices / machine-learning) |

Onboarding steps, the three DSN keys, and the per-driver gotchas:
`.agents/references/postgres-dragonfly.md`.

No dedicated instances are left (`AGENTS.md` § What was deliberately removed). Before you assume
that an app needs its own, check what the shared cluster already offers:
`SELECT name, default_version FROM pg_available_extensions`. Do not stand up a per-app CNPG
cluster or a sidecar Redis without a specific reason, and say the reason in the commit.

An app that supports SQLite can still use it, because that avoids a dependency entirely. If an
app needs a real database, share it. Do not silo it.

## Common Mistakes — Quick Reference

Rows marked (Artemis) do not hold on Frostlink. See `frostlink.md` § Common mistakes.

| Pattern                            | Correct                                                   | Wrong                                                               |
| ---------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------- |
| Secret store name                  | `onepassword-connect`                                     | `onepassword`, `1password-connect`                                  |
| Gateway, internal (Artemis)        | `internal-gateway`                                        | `internal`, `envoy-internal`                                        |
| Gateway, public (Artemis)          | `edge-gateway`                                            | `external-gateway` (exists, takes no new routes), `edge`, `towonel` |
| Gateway namespace                  | `network`                                                 | `default`, `networking`                                             |
| OCIRepository API                  | `source.toolkit.fluxcd.io/v1`                             | `v1beta2`                                                           |
| ExternalSecret API                 | `external-secrets.io/v1`                                  | `v1beta1`                                                           |
| Flux Kustomization API             | `kustomize.toolkit.fluxcd.io/v1`                          | `v1beta2`                                                           |
| Container image tag                | `v1.0.0@sha256:abc...`                                    | `latest`, bare `v1.0.0`                                             |
| OCIRepository chart tag            | bare version `2.5.0` (no SHA)                             | SHA-pinned (not used for Helm charts)                               |
| Timezone                           | never set `TZ`, k8tz handles it                           | `TZ: America/Toronto`                                               |
| HTTPRoute location (app-template)  | inline in helmrelease values                              | standalone HTTPRoute file                                           |
| Route gateway attachment (Artemis) | exactly one of internal/edge                              | one route on two gateways                                           |
| OCIRepository scope                | one per app                                               | shared across apps                                                  |
| Storage class (Artemis)            | `miroir` (default) or `miroir-local`, nothing else exists | `ceph-block`, `cephfs`, `ceph-filesystem`                           |
| Sonarr/Radarr/Prowlarr probe path  | `/ping`. Other apps have their own path, so check it      | `/`, `/health`                                                      |

## GPU Workloads (Artemis)

There are two allocation mechanisms, split by card, never by app. DRA claims serve the Arc A380
and the HD 530 iGPUs of the control-plane nodes. For example, Frigate gets an HD 530 through the
`frigate-igpu` `ResourceClaimTemplate`. `generic-device-plugin` still runs on ymir and offers its
iGPU for cross-namespace sharing (a `ResourceClaim` is namespace-scoped and cannot span
namespaces). No pod uses that lane today. Affinity keys on `node.kubernetes.io/gpu-tier`, never
`extensions.talos.dev/i915`. The details, the CEL selector rules and the `ResourceClaimTemplate`
immutability trap are in `.agents/references/gpu.md`.

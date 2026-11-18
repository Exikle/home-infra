# App Directory Structure — home-infra

These are the canonical shapes for an app directory. `cluster-conventions.md` § App Directory
Structure carries the rules (one `ks.yaml` per app, no grouping directory, alphabetical
`resources` in the `kustomization.yaml` of each namespace), and it wins. This file carries the
five shapes and their tradeoffs. Read it when you create an app, split a multi-component app, or
decide whether something is a fleet.

### Single-component app (the common case)

```text
kube/clusters/artemis/apps/<namespace>/<app>/
├── ks.yaml                  # one Flux Kustomization, name: <app>, path: .../<app>/app
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml   # standalone OCIRepository — every app gets its own
    └── helmrelease.yaml     # HTTPRoutes and ExternalSecrets defined in values here, not separate files
```

### Multi-component app

The app root has one `ks.yaml` with N Kustomization documents, one per sibling sub-directory.
The primary component keeps the name `app/`. The other components are named for what they are
(`microservices/`, `machine-learning/`, `cluster/`, `instance/`, `operator/`).

```text
kube/clusters/artemis/apps/media/immich/
├── ks.yaml                  # 3 Kustomizations: immich-app, immich-microservices,
│                            # immich-machine-learning
├── app/
├── machine-learning/
└── microservices/
```

The naming and label rules are in `cluster-conventions.md` § App Directory Structure, which wins.
Two examples from the tree:

- All the immich Kustomizations label `immich`, because the components are one product.
  `dependsOn` between them uses the `<app>-<component>` names.
- `observability/victoria` labels each component, because they are separate deployables. Its
  names (`vm-operator`, `vm-single`, `victoria-logs`) are a known exception to
  `<app>-<component>`.

### Operator and operand

If the operator serves the whole cluster, it gets its own namespace: `cnpg-system`,
`dragonfly-system`, `kopiur-system`, `external-secrets`. Operands then live in the consuming
namespace and use `dependsOn` across namespaces.

If the operand of the operator lives in the same namespace, the operator is a sub-directory of
the app directory of the operand. It is never a sibling top-level app directory.

```text
kube/clusters/artemis/apps/security/pocket-id/
├── ks.yaml                  # pocket-id-operator, pocket-id, pocket-id-groups,
│                            # pocket-id-extclients
├── operator/
├── instance/
├── groups/
└── external-clients/
```

Same shape:
`observability/victoria/{operator,app,agent,alert,logs}`,
`observability/grafana/{app,instance}`, `cortex/llmkube/{app,models}`.

### CR collections

A directory of many CRs of the same kind, reconciled by one Kustomization, is a sub-directory of
the app that owns the controller: `tuppr/upgrades/`, `silence-operator/silences/`,
`multus/networks/`, `renovate-operator/jobs/`, `pocket-id/groups/`, `llmkube/models/`.

### Fleets

Many similar workloads that are operationally one thing are one app directory with one
Kustomization. The members are kustomize sub-directories, wired by `resources:` in the parent
`kustomization.yaml`. Each member keeps its own `kustomization.yaml`, so a member can carry its
own `configMapGenerator` or extra resources.

```text
kube/clusters/artemis/apps/external-endpoints/services/
├── ks.yaml                  # ONE Kustomization, name: external-endpoints
└── app/
    ├── kustomization.yaml   # resources: ./forgejo ./pve ./templates ./truenas ./unifi
    ├── forgejo/
    ├── pve/
    ├── templates/
    ├── truenas/
    └── unifi/
```

The tradeoff is deliberate. One Kustomization means one failure domain, so a build error in one
member stalls them all. Before you commit, make sure that the fleet renders with
`mise run //kube/clusters/artemis:render-ks <ns> <ks>`. Prefer a fleet over N near-identical
`ks.yaml` files when N is more than about three and the members share a lifecycle and a single
controller.

Do not template a fleet into a component or a ResourceSet unless the members are uniform. A
component or ResourceSet is right when the resource skeleton is identical and only a few scalars
vary. Examples are `components/kopiur/backup` (`${APP}`, `${KOPIUR_CAPACITY}`),
`components/postgres/*` (`${APP}`), and the `agentgateway-opencode-go` ResourceSet in
`cortex/agentgateway/models/`. Members can differ in structure: different auth mechanisms, some
with a workload and some without, per-member volumes or RBAC. In that case, templating hides the
differences and breaks schema validation and editor completion. It also takes the pinned `image:`
lines out of reach of Renovate. Keep those as readable per-member manifests. `cortex/mcp` is that
case. It has several MCP servers (`ls kube/clusters/artemis/apps/cortex/mcp/app`) in one
`mcp-servers` Kustomization. Each has its own HelmRelease, because their RBAC, generated
ConfigMaps and secrets all differ.

### Shared apps (`kube/base/`)

An app that runs the same on both clusters lives once, in `kube/base/<ns>/<app>/`. The decision
and the rules are in #3333.

```text
kube/base/<ns>/<app>/
  kustomization.yaml   namespace: <ns>, resources: [./ks.yaml]
  ks.yaml              spec.path: ./kube/base/<ns>/<app>/app
  app/                 the same files as a cluster app
```

Each cluster that runs it lists the folder in its namespace menu,
`kube/clusters/<cluster>/apps/<ns>/kustomization.yaml`, as `- ../../../../base/<ns>/<app>`.
The menu lists the folder, not `ks.yaml`, because kustomize loads a file outside the menu folder
only through a folder that has its own `kustomization.yaml`.

The `namespace:` line in the base `kustomization.yaml` is required. Flux gets the namespace from
the menu, but flate (behind `render-ks` and kritika's renders) takes it from the folder that holds
`ks.yaml`. Without the line, flate renders the Kustomizations with no namespace and their
`dependsOn` fail.

A file in `kube/base/` never names a cluster. A change there reaches both clusters in one push,
so test it on both clusters before you commit.

#### Per-cluster values and extras

When a shared app differs on one cluster, the base HelmRelease reads an optional ConfigMap, and
only that cluster creates it. `cert-manager` is the example:

```text
kube/base/cert-manager/cert-manager/app/helmrelease.yaml
  valuesFrom: ConfigMap cert-manager-values, valuesKey values.yaml, optional: true
kube/clusters/artemis/apps/cert-manager/cert-manager/extras/
  ks.yaml              Kustomization cert-manager-extras
  kustomization.yaml   configMapGenerator cert-manager-values from values.yaml
  values.yaml          only the values that differ on Artemis
  grafanadashboard.yaml, prometheusrule.yaml   objects only Artemis runs
```

The base Kustomization has `dependsOn: <app>-extras`, so every cluster that runs the app has an
`extras` folder, and the menu of each lists the base folder and `./<app>/extras/ks.yaml`. A
cluster with no differences uses `{}` as its `values.yaml`. Without the `dependsOn`, the
HelmRelease can install before the ConfigMap exists. Flux then installs it with the base values
only, and flate renders it that way (seen with metrics-server).

Flux merges `valuesFrom` first and the inline `values` last, so the inline values win. The base
HelmRelease must therefore hold only the values that every cluster shares. A key that differs
goes in the `values.yaml` of each cluster, never in the base. If the base sets it, the cluster
value is silently lost.

Put the ConfigMap inside the `extras` Kustomization, not in the namespace menu. flate does not
render the root Kustomization, so it cannot see objects that only the menu creates. Do not give
`extras` a `dependsOn` on the app, or the two wait on each other. The ConfigMap carries
`reconcile.fluxcd.io/watch: Enabled`, so a change to it starts a Helm upgrade.

`render-ks` sets `FLATE_ALLOW_MISSING_SECRETS=true`, and with that flag flate skips every
`valuesFrom` reference. So `render-ks` shows the base values only. To see the values of a cluster,
run `flate build hr --path <artifact> --namespace <ns> <name>` without the flag.

### Non-standard resource types

The rule (one resource per file, the filename is the lowercased kind, flat in the leaf directory)
is in `cluster-conventions.md` § App Directory Structure, which wins. Examples:
`grafanadashboard.yaml`, `servicemonitor.yaml`, `networkpolicy.yaml`, `securitypolicy.yaml`,
`oidcclient.yaml`, `resourceset.yaml`. A ClusterRole, its Binding and its ServiceAccount go
together in a single `rbac.yaml`.

A deployment that is not app-template has no `values.route` to write into. It gets a standalone
`httproute.yaml`. `find kube -name httproute.yaml` lists those files.

Non-YAML configuration payloads go in a `resources/` (or `config/`) sub-directory of the leaf
directory. A `configMapGenerator` mounts them, with `disableNameSuffixHash: true` and the
`kustomize.toolkit.fluxcd.io/substitute: disabled` annotation.

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

- Kustomization names are `<app>-<component>`. `dependsOn` between them uses those names.
- When the components are one product, `commonMetadata.labels.app.kubernetes.io/name` is the app,
  not the component (all the immich Kustomizations label `immich`). Where the components are
  genuinely separate deployables, label the component (`victoria-operator` vs `victoria-app`).

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
`observability/grafana/{app,instance}`, `cortex/llmkube/{app,models}`,
`cert-manager/trust-manager/{app,config}`.

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
    ├── forgejo/{kustomization,envoyextensionpolicy,inputs}.yaml
    ├── pve/
    ├── templates/
    ├── truenas/
    └── unifi/
```

The tradeoff is deliberate. One Kustomization means one failure domain, so a build error in one
member stalls them all. Validate with `mise run //kube/clusters/artemis:render-ks <ns> <ks>` before you commit. Prefer a
fleet over N near-identical `ks.yaml` files once N is more than about three and the members share
a lifecycle and a single controller.

Do not template a fleet into a component or a ResourceSet unless the members are genuinely
uniform. A component or ResourceSet earns its place when the resource skeleton is identical and
only a handful of scalars vary. Examples are `components/kopiur/backup` (`${APP}`,
`${KOPIUR_CAPACITY}`), `components/postgres/*` (`${APP}`), and the `agentgateway-opencode-go`
ResourceSet in `cortex/agentgateway/models/`. Members can differ structurally: different auth
mechanisms, some with a workload and some without, per-member volumes or RBAC. In that case,
templating hides the differences, breaks schema validation and editor completion, and takes the
pinned `image:` lines out of reach of Renovate. Keep those as readable per-member manifests.
`cortex/mcp` is that case. It has ten MCP servers in one `mcp-servers` Kustomization, each with
its own HelmRelease, because their RBAC, generated ConfigMaps and secrets all differ.

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
the menu, but flate (behind `render-ks` and konflate) takes it from the folder that holds
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

The menu of that cluster lists the base folder and `./<app>/extras/ks.yaml`. A cluster without
differences lists only the base folder.

Put the ConfigMap inside the `extras` Kustomization, not in the namespace menu. flate does not
render the root Kustomization, so it cannot see objects that only the menu creates. Do not give
`extras` a `dependsOn` on the app. Then the ConfigMap can exist before the HelmRelease first
installs. The ConfigMap carries `reconcile.fluxcd.io/watch: Enabled`, so a change to it starts a
Helm upgrade.

`render-ks` sets `FLATE_ALLOW_MISSING_SECRETS=true`, and with that flag flate skips every
`valuesFrom` reference. So `render-ks` shows the base values only. To see the values of a cluster,
run `flate build hr --path <artifact> --namespace <ns> <name>` without the flag.

### Non-standard resource types

One resource per file, filename = lowercased kind, flat in the leaf directory alongside
`helmrelease.yaml`, listed alphabetically in the `kustomization.yaml` of that directory. There is
no `rbac/`, `monitoring/`, or `network/` sub-directory. Examples: `grafanadashboard.yaml`,
`servicemonitor.yaml`, `networkpolicy.yaml`, `securitypolicy.yaml`, `oidcclient.yaml`,
`resourceset.yaml`. ClusterRole + Binding + ServiceAccount go together in a single
`rbac.yaml`.

`HTTPRoute` is inline under `route.app:` in app-template values. The only exception is a
non-app-template deployment with no `values.route` to write into. It gets a standalone
`httproute.yaml` (`flux-system/flux-webhook`, `network/echo`, `cortex/agentgateway`).

Non-YAML configuration payloads go in a `resources/` (or `config/`) sub-directory of the leaf
directory. They are mounted via `configMapGenerator` with `disableNameSuffixHash: true` and the
`kustomize.toolkit.fluxcd.io/substitute: disabled` annotation.

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

An app that both clusters run is a shared app. It lives once, complete, in
`kube/base/<ns>/<app>/`: its `ks.yaml` and its manifests. A folder in a cluster's `apps/` is one
of two things:

- With a `ks.yaml`, it is an app that only that cluster runs.
- Without a `ks.yaml`, it holds what is different on that cluster for a shared app.

A shared app with no differences has no folder in any cluster.

```text
kube/base/kube-system/
  kustomization.yaml     namespace: kube-system, lists the shared ks.yaml files
  reloader/              no differences, so no cluster folder
    ks.yaml              path: ./kube/base/kube-system/reloader/app, reads the flux-system OCIRepository
    app/                 kustomization.yaml, helmrelease.yaml, ocirepository.yaml
  k8tz/                  differences on each cluster
    ks.yaml              path: ./kube/clusters/${CLUSTER}/apps/kube-system/k8tz/app
    app/
kube/base/kustomization.yaml   lists every kube/base/<ns>/ menu
kube/clusters/<cluster>/apps/
  flux-system/base/ks.yaml     the Flux Kustomization `base`: path ./kube/base, CLUSTER=<cluster>
  kube-system/k8tz/app/        the differences of this cluster, no ks.yaml
  kube-system/descheduler/     an app that only this cluster runs, with its ks.yaml
```

The Flux Kustomization `base` in `apps/flux-system/base/ks.yaml` is the only link from a cluster
to `kube/base/`. The `flux-system` menu of the cluster lists it, and `base` then applies all of
`kube/base/`. It fills in `${CLUSTER}` with `postBuild.substitute`. The root cannot do that job,
because about 47 cluster `ks.yaml` files carry variables such as `${APP}` for their own
Kustomization. No file in `kube/base/` may use any `${...}` variable other than `${CLUSTER}`. A
cluster menu never lists `kube/base/`. The namespace menus of the cluster keep the alerts
component, the other namespace components, and the apps that only that cluster runs. They do not
list the folders of shared apps, because those folders have no `ks.yaml`.

The FluxInstance gives the root Kustomization a patch that sets the Flux defaults on every
Kustomization that the root applies: `deletionPolicy`, `retryInterval`, and the HelmRelease
defaults (`crds: CreateReplace`, the remediation settings). That patch replaces the
`spec.patches` of its target, and it does not reach the Kustomizations that `base` applies. So:

- The root patch skips every Kustomization with the label
  `home-infra/flux-defaults: from-component`. The `base` Kustomization carries that label, so its
  own per-cluster patches stay.
- `kube/base/kustomization.yaml` uses the component `kube/components/flux-defaults`, which sets
  the same defaults on every shared Kustomization. If you change the defaults, change both the
  component and the FluxInstance patch in `flux-instance/app/helmrelease.yaml`.

Every namespace lives once, in `kube/base/<ns>/namespace.yaml`, and its base menu lists it. Both
clusters get every namespace, so a cluster can hold a namespace that it runs nothing in. Where the
two clusters used to label a namespace differently, the base file carries the labels of both
(2026-11-22), so no namespace lost a label. Every namespace carries
`kustomize.toolkit.fluxcd.io/prune: disabled`. A cluster menu never lists a `namespace.yaml`.

Every `spec.path` of a shared app points at a real folder in git:

- `./kube/clusters/${CLUSTER}/apps/<ns>/<app>/<folder>` when the clusters have differences. Then
  every cluster needs that folder, even if one of them only lists the base folder. The
  Kustomization reads its own `ExternalArtifact`.
- `./kube/base/<ns>/<app>/<folder>` when no cluster has differences. No cluster folder exists, so
  the generator makes no artifact for the app. The Kustomization reads the whole artifact of the
  cluster instead (`sourceRef: {kind: OCIRepository, name: flux-system, namespace: flux-system}`).
  It then reconciles on every push, which costs little. If the app later gets a difference,
  create the cluster folders and switch both `path` and `sourceRef`.

`scripts/check-kube-menus.py` (an `hk` step) enforces the shape:

- Every shared app has a `ks.yaml`, and its base menu lists it.
- `kube/base/kustomization.yaml` lists every base menu.
- `apps/flux-system/base/ks.yaml` has `path: ./kube/base`, and no cluster menu lists `kube/base/`.
- Every namespace folder in a cluster's `apps/` has a `kustomization.yaml`. Without one, the
  root would walk into the folder and apply the files of a shared app directly.
- Every `spec.path` of a shared app exists for every cluster, with `${CLUSTER}` filled in.
- A cluster folder named like a shared app has no `ks.yaml`. A cluster folder without a `ks.yaml`
  belongs to a shared app whose `ks.yaml` points into the cluster's `apps/`.
- No cluster has an `overlays/` folder.

A change in `kube/base/` reaches both clusters in one push, so test it on both clusters before you
commit.

#### Per-cluster differences

The differences of a cluster for a shared app go in `kube/clusters/<cluster>/apps/<ns>/<app>/`,
with no `ks.yaml`. That folder mirrors the base app, and the shared `ks.yaml` points at it. Its
`kustomization.yaml` lists the base folder as a resource and adds what differs. `cert-manager` is
the example:

```text
kube/base/cert-manager/cert-manager/app/helmrelease.yaml
  valuesFrom: ConfigMap cert-manager-values, valuesKey values.yaml, optional: true
kube/clusters/artemis/apps/cert-manager/cert-manager/app/
  kustomization.yaml     resources: ../../../../../../base/cert-manager/cert-manager/app,
                         plus the files below. configMapGenerator cert-manager-values
                         from values.yaml, label reconcile.fluxcd.io/watch: Enabled
  values.yaml            only the values that differ on Artemis
  grafanadashboard.yaml, prometheusrule.yaml   objects only Artemis runs
```

The artifact keeps every folder at its repo path, so the `../../../../../../base` path works both
in the repo and in the artifact. A cluster folder can also add a folder that the base does not have, for
example the backup repository of kopiur in `apps/kopiur-system/kopiur/repository/`.

The ConfigMap and the HelmRelease come from one Kustomization, so they need no `dependsOn` between
them.

A Kustomization field that differs per cluster, for example an extra `dependsOn`, cannot go in the
shared `ks.yaml`. It goes in a `patches:` entry of the `base` Kustomization in
`apps/flux-system/base/ks.yaml` of that cluster.
Artemis adds `dependsOn: cert-manager` to `k8tz`. Frostlink adds `fediverse/apoci` and
`network/envoy-gateway` to `flux-instance`. A Kustomization that only one cluster runs is its own
cluster app, for example `apps/flux-system/flux-operator-oidc/` on Artemis.

Flux merges `valuesFrom` first and the inline `values` last, so the inline values win. The base
HelmRelease must therefore hold only the values that every cluster shares. A key that differs
goes in the `values.yaml` of each cluster, never in the base. If the base sets it, the cluster
value is silently lost.

Put the ConfigMap in the `app/` folder of the cluster, not in the namespace menu. flate does not
render the root Kustomization, so it cannot see objects that only the menu creates. The
ConfigMap carries `reconcile.fluxcd.io/watch: Enabled`, so a change to it starts a Helm upgrade.

`render-ks` renders the Flux objects of one Kustomization, not the output of the chart. So it does
not show the values that a HelmRelease gets. To see the chart output with the values of a
cluster, run `flate build all --path kube/clusters/<cluster>`. Then select the objects that carry
the label `helm.toolkit.fluxcd.io/name: <name>`. That render applies the `valuesFrom` ConfigMap of
the cluster. On flate 0.8.0, do not use `flate build hr` or `flate build all --namespace`. Both
hang (#3406).

### Per-app artifacts

CI publishes one artifact per cluster (`ci.md` § `oci-push`), and the `flux-system` OCIRepository
pulls it. In each cluster, one Flux `ArtifactGenerator`, `apps`, cuts that artifact into one
artifact per app. source-watcher runs it. It lives in `kube/base/flux-system/artifactgenerator.yaml`,
and both clusters apply that same file.

It uses `pathPattern: "@repo/kube/clusters/{cluster}/apps/{namespace}/{app}"`. The artifact of a
cluster holds only its own cluster folder, so `{cluster}` matches exactly one name. For each app
folder, it makes one `ExternalArtifact` named `{app}` in the namespace `{namespace}`. So two apps
with the same folder name in two namespaces (for example `agentgateway`) do not clash. Each
artifact holds these folders, at their repo paths:

- The app folder, `kube/clusters/<cluster>/apps/{namespace}/{app}/`.
- `kube/base/{namespace}/{app}/`, if it exists. A shared app gets its base files this way.
- `kube/clusters/<cluster>/components/`.
- `kube/components/`.

The generator finds apps only by their folders, never by their files. One generator for one
folder tree means that no two generators make an artifact with the same name. Before 2026-11-23,
a second `base` generator did, and the two deleted each other's artifacts.
`apps/flux-system/base/` also gets an artifact that nothing reads, because `base` reads the
whole artifact.

`originRevision: "@repo"` gives each artifact the git revision of the source.

An app Kustomization with a cluster folder reads its own artifact:

```yaml
sourceRef:
    kind: ExternalArtifact
    name: <app folder name>
```

The artifact lives in the namespace of the Kustomization, so `sourceRef` has no `namespace`. The
name is the app folder, not the Kustomization name. All the Kustomizations in one `ks.yaml` read
the same artifact (for example `trust-manager` and `trust-manager-config`). The root `flux-system`
Kustomization, the `base` Kustomization and the shared apps with no differences read the
`flux-system` OCIRepository. So do the Kustomizations that a component or a ResourceSet
generates.

A push therefore reconciles only the apps whose files changed. A change to a shared component
changes every artifact, so it reconciles every app. `dependsOn` waits for the matching revision
only when both Kustomizations read the same artifact, that is the same app folder. Across apps,
`dependsOn` gives order only. `land` waits until the `ExternalArtifact` of each target carries
the pushed revision before it resumes.

If an artifact goes missing (for example after a folder moves), run
`mise run //kube/clusters/<cluster>:sync-flux artifactgenerator apps`. Otherwise the generator
repairs it within an hour.

flate 0.8.0 cannot run the generator. It does not read `artifacts[].namespace` or
`copy[].optional`. So every offline render first runs `scripts/flate-offline.sh <tree> <cluster>`
on a copy of the tree. The script points each app Kustomization back at the whole tree and
deletes the generator from the copy. Every folder that the generator copies already sits at its
repo path, so nothing else needs to be built. The offline render does not test the copy rules of
the generator. `render-ks`, the CI render and the kritika review all use the script.

The layout has one home per app, not one artifact per namespace or per path prefix. Every path is
a real folder in git, as in the upstream `flux2-kustomize-helm-example`. The only cluster name in
`kube/base/` is the `${CLUSTER}` variable, and the artifact names stay plain. Components that one
cluster uses stay in that cluster. #3460 reviews which of them both clusters could share. This
layout supersedes #3459 (flatten `extras/`).

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

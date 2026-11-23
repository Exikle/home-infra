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
`kube/base/<ns>/<app>/`: its `ks.yaml` and its manifests. A cluster folder holds only what is
different on that cluster. A shared app with no differences has no folder in any cluster.

```text
kube/base/kube-system/
  kustomization.yaml     namespace: kube-system, lists ./reloader/ks.yaml and the other shared apps
  reloader/              no differences, so no cluster folder
    ks.yaml              spec.path: ./kube/clusters/current/apps/kube-system/reloader/app
    app/                 kustomization.yaml, helmrelease.yaml, ocirepository.yaml
kube/base/kustomization.yaml   lists every kube/base/<ns>/ menu
kube/clusters/<cluster>/apps/base/kustomization.yaml   resources: ../../../../base
```

The file `apps/base/kustomization.yaml` is the only link from a cluster to `kube/base/`. The root
Kustomization of the cluster finds it like any other folder in `apps/`. A cluster menu never lists
`kube/base/`. The namespace menus of the cluster keep the `namespace.yaml`, the alerts component
and the apps that only that cluster runs.

Every `spec.path` of a shared app starts with `./kube/clusters/current/apps/<ns>/<app>/`. That
folder exists only inside the artifact of the app. The `base` generator builds it from the base
app plus the overlay of the cluster (§ Per-app artifacts). So one `ks.yaml` works on both
clusters, with no cluster name and no substitution.

`scripts/check-kube-menus.py` (an `hk` step) enforces the shape:

- Every shared app has a `ks.yaml`, and its base menu lists it.
- `kube/base/kustomization.yaml` lists every base menu.
- `apps/base/kustomization.yaml` lists exactly `../../../../base`, and no other cluster menu
  lists `kube/base/`.
- A shared app has no folder in a cluster's `apps/`. Both would publish an artifact with the
  same name.
- Every `overlays/<ns>/<app>/` belongs to a shared app.

A change in `kube/base/` reaches both clusters in one push, so test it on both clusters before you
commit.

#### Per-cluster differences

The differences of a cluster for a shared app go in `kube/clusters/<cluster>/overlays/<ns>/<app>/`.
That folder mirrors the base app. The generator copies it on top of the base, so a file in the
overlay replaces the base file with the same path. `cert-manager` is the example:

```text
kube/base/cert-manager/cert-manager/app/helmrelease.yaml
  valuesFrom: ConfigMap cert-manager-values, valuesKey values.yaml, optional: true
kube/clusters/artemis/overlays/cert-manager/cert-manager/app/
  kustomization.yaml     replaces the base one. resources: ../../../../../../base/cert-manager/cert-manager/app,
                         plus the files below. configMapGenerator cert-manager-values
                         from values.yaml, label reconcile.fluxcd.io/watch: Enabled
  values.yaml            only the values that differ on Artemis
  grafanadashboard.yaml, prometheusrule.yaml   objects only Artemis runs
```

The `../../../../../../base` path works both in the repo and in the artifact. `overlays/` sits at
the same depth as `apps/`, and `current/` sits at the same depth as a cluster folder. An overlay
can also add a folder that the base does not have, for example the backup repository of kopiur
in `overlays/kopiur-system/kopiur/repository/`.

The ConfigMap and the HelmRelease come from one Kustomization, so they need no `dependsOn` between
them.

A Kustomization field that differs per cluster, for example an extra `dependsOn`, cannot go in the
shared `ks.yaml`. It goes in a `patches:` entry of `apps/base/kustomization.yaml` of that cluster.
Artemis adds `dependsOn: cert-manager` to `k8tz`. Frostlink adds `fediverse/apoci` and
`network/envoy-gateway` to `flux-instance`. A Kustomization that only one cluster runs is its own
cluster app, for example `apps/flux-system/flux-operator-oidc/` on Artemis.

Flux merges `valuesFrom` first and the inline `values` last, so the inline values win. The base
HelmRelease must therefore hold only the values that every cluster shares. A key that differs
goes in the `values.yaml` of each cluster, never in the base. If the base sets it, the cluster
value is silently lost.

Put the ConfigMap in the `app/` folder of the overlay, not in the namespace menu. flate does not
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
pulls it. In each cluster, two Flux `ArtifactGenerator`s cut that artifact into one artifact per
app. source-watcher runs them. Both read the `flux-system` OCIRepository. For each app folder,
each makes one `ExternalArtifact` named `{app}` in the namespace `{namespace}`. So two apps with
the same folder name in two namespaces (for example `agentgateway`) do not clash.

Both generators live once, in `kube/base/flux-system/artifactgenerator.yaml`, and both clusters
apply that same file.

The `apps` generator serves the apps that
only one cluster runs. It uses
`pathPattern: "@repo/kube/clusters/{cluster}/apps/{namespace}/{app}"`. The artifact of a cluster
holds only its own cluster folder, so `{cluster}` matches exactly one name and the file needs no
cluster name. Each of its artifacts holds these folders, at their repo paths:

- The app folder, `kube/clusters/<cluster>/apps/{namespace}/{app}/`.
- `kube/base/{namespace}/{app}/`, if it exists.
- `kube/clusters/<cluster>/components/`.
- `kube/components/`.

The `base` generator serves the shared apps.
It uses `pathPattern: "@repo/kube/base/{namespace}/{app}"`. That pattern has no cluster to
capture, so the file names the overlay and components folders of Artemis. The
`apps/base/kustomization.yaml` of Frostlink patches those two paths to its own folders. A `*` in
place of the cluster name does not work: the generator then keeps the whole matched path, and the
overlay never lands on top of the base. Each of its artifacts holds:

- `kube/base/{namespace}/{app}/`, at its repo path.
- `kube/clusters/current/apps/{namespace}/{app}/`: a copy of the base app without its `ks.yaml`,
  then the overlay of the cluster on top. A later copy replaces a file of an earlier one.
- The `current/components/` folder: the components of the cluster.
- `kube/components/`.

The two generators never make an artifact with the same name, because a shared app has no folder
in a cluster's `apps/`. `check-kube-menus.py` enforces that.

`originRevision: "@repo"` gives each artifact the git revision of the source.

Every app Kustomization reads its own artifact:

```yaml
sourceRef:
    kind: ExternalArtifact
    name: <app folder name>
```

The artifact lives in the namespace of the Kustomization, so `sourceRef` has no `namespace`. The
name is the app folder, not the Kustomization name. All the Kustomizations in one `ks.yaml` read
the same artifact (for example `cnpg` and `plugin-barman-cloud`). The root `flux-system`
Kustomization still reads the `flux-system` OCIRepository. So do the Kustomizations that a
component or a ResourceSet generates.

A push therefore reconciles only the apps whose files changed. A change to a shared component
changes every artifact, so it reconciles every app. `dependsOn` waits for the matching revision
only when both Kustomizations read the same artifact, that is the same app folder. Across apps,
`dependsOn` gives order only. `land` waits until the `ExternalArtifact` of each target carries
the pushed revision before it resumes.

flate 0.8.0 cannot run these generators. It does not read `artifacts[].namespace` or
`copy[].optional`. So every offline render first runs `scripts/flate-offline.sh <tree> <cluster>`
on a copy of the tree. The script builds the `current/` folder the way the `base` generator
does, and then deletes the cluster's `overlays/`, so that flate sees each object once. It points
each app Kustomization back at the whole tree and deletes the generators from the copy. The
offline render does not test the copy rules of the generators. `render-ks`, the CI render and the
kritika review all use the script. If a shared app keeps its `ks.yaml` inside `current/`, flate
sees each Kustomization twice and hangs. That is why both the generator and the script leave it
out.

The layout has one home per app, not one artifact per namespace or per path prefix. That keeps
`kube/base/` free of cluster names and keeps the artifact names plain. Components that one
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

# Reference: Observability — home-infra

## Grafana Operator

- The namespace of a `GrafanaDashboard` is the name of its Grafana folder. Always deploy a
  GrafanaDashboard in the namespace of its app (for example `miroir-system` or `kopiur-system`),
  never in `default`.
- Grafana is a `Grafana` CR (`observability/grafana/instance/grafana.yaml`). The operator
  reconciles it into Deployment `grafana-deployment`. It is not an app-template HelmRelease. There
  is no `GrafanaFolder` CR.
- Grafana is stateless. Its database is the shared Postgres (`grafana` on `postgres-rw`,
  `sslmode=verify-full`), and `/var/lib/grafana` is an `emptyDir`. There is no PVC. Everything that
  Grafana serves comes from CRDs. The admin password comes from an ExternalSecret, and users come
  from Pocket-ID OIDC. A wiped pod loses nothing. Plugins download again on start.
- One thing is not in Git: the `grafana-mcp` service account and its token. The token value is in
  1Password, but the account itself is in the Postgres database. If anyone rebuilds that database,
  recreate the service account in the UI and update `GRAFANA_SERVICE_ACCOUNT_TOKEN`. If you do not,
  the Grafana MCP server breaks.
- A stale GrafanaDashboard in `default` overrides the copy in the correct namespace. `default` is
  clean now. If a folder looks wrong in Grafana, run `kubectl get grafanadashboard -n default`
  first.

### `datasourceName` is the CR's `spec.datasource.name`, not the CR's own name

A wrong name is the most common reason that a dashboard renders with empty panels. Four
datasources exist. Two of them have a CR name that differs from the datasource name:

| CR (`grafanadatasource` in `observability`) | `datasourceName` to use in a dashboard | Type                              |
| ------------------------------------------- | -------------------------------------- | --------------------------------- |
| `prometheus`                                | `prometheus`                           | `prometheus`                      |
| `alertmanager`                              | `alertmanager`                         | `alertmanager`                    |
| `victoria-logs`                             | `VictoriaLogs`                         | `victoriametrics-logs-datasource` |
| `victoriametrics`                           | `VictoriaMetrics`                      | `prometheus`                      |

`prometheus` and `victoriametrics` both point at
`http://victoria-metrics-server.observability.svc.cluster.local:8428`. The first is the
compatibility name that most vendored dashboards expect. The second has the native type. Both work
for metrics. Do not merge them, because vendored dashboards hardcode `prometheus`.

Before you write a dashboard, make sure that the names are right:

```bash
kubectl get grafanadatasource -A \
  -o custom-columns=CR:.metadata.name,NAME:.spec.datasource.name,TYPE:.spec.datasource.type
```

## ServiceMonitor / PodMonitor Bootstrap Gap

A HelmRelease that renders a `ServiceMonitor` or `PodMonitor` fails when the
`monitoring.coreos.com` CRDs do not exist yet. The CRDs come from bootstrap, not from Flux
(§ Where the `monitoring.coreos.com` CRDs come from).

On Artemis, the `base` stage of bootstrap applies the CRDs from `helmfile.d/00-crds.yaml` before
the `apps` stage starts Flux. So the gap happens only when that CRD step was skipped or failed.

To recover, do these steps:

1. Apply the CRDs again from `kube/clusters/artemis/bootstrap/helmfile.d/00-crds.yaml`.
2. Force-sync each HelmRelease that failed to create its monitor:
   `mise run //kube/clusters/artemis:sync-flux hr <app>`.

## What the metrics stack actually is

Metrics are VictoriaMetrics, put together piece by piece under `observability/victoria/`. The VM
operator watches `ServiceMonitor`, `PodMonitor` and `PrometheusRule`. It copies each one into its
own `VMServiceScrape`, `VMPodScrape` or `VMRule`. So both APIs are live, and a chart that ships
either one works with no change.

| Directory   | What it is                                                                                                          | Resulting workload                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `operator/` | `victoria-metrics-operator` chart                                                                                   | Deployment `vm-operator`              |
| `agent/`    | plain manifests, no HelmRelease: a `VMAgent` CR plus the kubelet `VMNodeScrape`s and the pantheon `VMStaticScrape`s | Deployment `vmagent-vmagent`          |
| `app/`      | `victoria-metrics-single` chart                                                                                     | StatefulSet `victoria-metrics-server` |
| `alert/`    | plain manifests, no HelmRelease: a `VMAlert` CR plus the `cluster-baseline` `VMRule`                                | Deployment `vmalert-vmalert`          |
| `logs/`     | `victoria-logs-single` chart                                                                                        | StatefulSet `victoria-logs-server`    |

The names suggest a wrong shape. Keep these two facts in mind:

- There is no `VMSingle` or `VMAlertmanager` CR. The metrics store is an ordinary chart workload.
  `kubectl get vmsingle -A` returns nothing, and that is correct. `VMAgent` and `VMAlert` are the
  only VM operator instance CRs in the cluster.
- Alertmanager is its own app-template HelmRelease (`observability/alertmanager`, StatefulSet
  `alertmanager`). No VM chart bundles it.

### kube-prometheus-stack was here, and left litter

A `kube-prometheus-stack` ran in `observability` until about 2026-05-16. Nothing in
`kube/clusters/artemis/` references it now. For that reason, Flux will never prune what it left:

| Leftover                                                           | Cost            |
| ------------------------------------------------------------------ | --------------- |
| `VMRule` `kube-prometheus-stack-kube-apiserver-availability.rules` | still evaluated |
| `VMRule` `kube-prometheus-stack-kube-apiserver-burnrate.rules`     | still evaluated |

The VMRules carry `helm.toolkit.fluxcd.io/name: kube-prometheus-stack` labels and no
`ownerReferences`. Their deletion is
[#2764](https://git.dcunha.io/Exikle/home-infra/issues/2764). They are orphans, not managed state.
Do not look for the manifest that produces them. You can delete them safely. Nobody has done it
yet.

### Where the `monitoring.coreos.com` CRDs come from

The chart name stays in one live place, and it is not a deployment.
`kube/clusters/artemis/bootstrap/helmfile.d/00-crds.yaml` carries a `kube-prometheus-stack`
release that is never installed. `base` renders it and keeps `kind: CustomResourceDefinition`. It
throws the rest away: a `Prometheus` CR, an `Alertmanager`, the Deployments, a DaemonSet, both
operator webhooks and the PrometheusRules. That one `yq` filter is the only thing that keeps a
second metrics stack out of the cluster.

This step is load-bearing, because nothing under `kube/clusters/artemis/` installs those CRDs.
`crds.enabled: true` of vm-operator ships the VictoriaMetrics CRDs. Its
`disable_prometheus_converter: false` only makes it watch `ServiceMonitor`, `PodMonitor`,
`PrometheusRule` and `Probe`, which the repo uses everywhere. Only bootstrap registers those kinds.

The CRDs in the cluster today are still the CRDs of the dead release (field manager
`helm-controller`, `helm.toolkit.fluxcd.io/name: kube-prometheus-stack`). Nothing applied them
again after about 2026-05-16. So a Renovate bump on that chart version changes nothing live. It
only picks which CRD schemas the next rebuild installs.

## Kubelet / cAdvisor Scraping

Nothing scrapes the kubelet unless we create the scrape. Every other target in this cluster comes
from a `ServiceMonitor` that its own chart ships, and the VM operator converts it. The kubelet has
no chart. The `victoria-metrics-k8s-stack` chart supplies these objects, but this cluster puts
VictoriaMetrics together piece by piece (see the table above). So nobody created them.

Without them, the cluster has no `container_*` metrics at all. It has no
`container_memory_working_set_bytes` and no `container_cpu_usage_seconds_total`. So it has no way
to compute a p95 for any workload. This fault is easy to bring back.

`victoria/agent/vmnodescrape-kubelet.yaml` supplies them. It holds three `VMNodeScrape` objects,
`kubelet`, `kubelet-cadvisor` and `kubelet-resource`, for `/metrics`, `/metrics/cadvisor` and
`/metrics/resource`. The spec follows the `kubelet` block of the `values.yaml` of the upstream
chart. When the spec needs an update, look there.

All three relabel to `job="kubelet"`. The `VMNodeScrape` object names are not job names. So
`{job="kubelet-cadvisor"}` matches nothing, and the scrape looks broken. Query
`container_memory_working_set_bytes{job="kubelet"}`. To make sure that the scrape is alive, run
`count(container_memory_working_set_bytes)`.

RBAC needs nothing. The operator already grants `nodes/metrics` to the VMAgent ServiceAccount.

### Three things in that file that are load-bearing

`honorTimestamps: false`: cAdvisor exports stale timestamps. If vmagent keeps them, they produce gaps
and out-of-order rows. Upstream sets it for the same reason
([VictoriaMetrics#4697](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4697)).

`labeldrop` of `(id|name)`: These labels are the cgroup path and the container runtime id. Each
container restart gives them a new value. So they fork the series on every restart, and no query
uses them. Upstream drops them. Keep the drop.

`labeldrop` of `extensions_talos_dev_.*|tuppr_home_operations_com_.*|beta_kubernetes_io_.*`: This
one is ours, not upstream's. The blanket `labelmap __meta_kubernetes_node_label_(.+)` above it is
upstream's. On Talos, it brings in labels that change:

- `extensions.talos.dev/*` carries a version for each system extension (`i915`, `intel-ucode`,
  `kata-containers`, and others). It changes on every Talos or extension bump, and Renovate does
  those bumps often.
- `tuppr.home-operations.com/upgrading`: tuppr adds it at the start of an upgrade and removes it
  at the end.

Each of those changes forks every container series on that node into a new series. The labels
`node` and `instance` already carry the node identity, and you can join node attributes from
`kube_node_labels`. The configuration keeps stable node labels on purpose (`topology_*`,
`node_kubernetes_io_gpu*`, `bgppolicy`). It drops only the label families that change.

### Cost

cAdvisor adds tens of thousands of series. If that becomes a problem, drop unused cAdvisor metric
families in `metricRelabelConfigs`. Do not shorten retention. To measure again, run:

```bash
kubectl port-forward -n observability svc/victoria-metrics-server 18428:8428
curl -s 'localhost:18428/api/v1/query?query=sum(vm_cache_entries{type="storage/hour_metric_ids"})'
```

## prometheus-adapter is a cluster-wide dependency, not an observability nicety

`observability/prometheus-adapter` backs the `v1beta1.external.metrics.k8s.io` APIService. It is
the only provider of it. Every `components/zeroscaler` HPA scales on an `External` metric. For the
current set, which spans more than one namespace, run
`grep -rln 'components/zeroscaler' kube/clusters/artemis/apps/`.

```text
probe_success{job="blackbox-tcp"}  →  target value 1  →  minReplicas 0 / maxReplicas 1
```

So the wake-up path is a chain. If any link breaks, every zeroscaled app stays at zero replicas at
the same time:

```text
blackbox-exporter → vmagent → victoria-metrics-server → prometheus-adapter → HPA → Deployment
```

`prometheus-adapter` reads `http://victoria-metrics-server.observability.svc.cluster.local` on port
8428 (`prometheus.port` in its HelmRelease). Nothing else shows it. It has no route and no
dashboard, and nothing alerts when the APIService goes `False`. To diagnose a cluster-wide
"everything in media is down", run:

```bash
kubectl get apiservice v1beta1.external.metrics.k8s.io
kubectl get hpa -A
```

`AVAILABLE=False` on that APIService, or `<unknown>/1` in the HPA `TARGETS` column, means that the
adapter is the fault, not the apps. See `.agents/references/media-stack.md` § Scale-to-zero.

### blackbox-exporter must never run BestEffort

It is the head of that chain, and one pod serves the whole cluster. With no resource requests, it
ran BestEffort. CPU contention on a busy node starved its probe goroutines, and it missed its own
liveness probe. That took `probe_success` with it, and every scale-to-zero app went idle at once.
So the HelmRelease sets CPU and memory requests (a guaranteed share). It sets no CPU limit on
purpose, so the exporter can still burst through a probe sweep without throttling. Do not add a
CPU limit back.

## Other observability workloads worth knowing exist

No other section of this file covers these apps, and it is easy to mistake them for something else:

| App                 | What it is                                                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `siren`             | Alertmanager web UI at `siren.dcunha.io` (internal). Reads the shared Alertmanager. Holds no state of its own                                                       |
| `silence-operator`  | Declarative Alertmanager silences as CRs. A `VMPodScrape` scrapes it, not a Service                                                                                 |
| `gatus-sidecar`     | Gatus with no page of its own. It checks the home apps and pushes the results to Frostlink, which serves `status.dcunha.io`. See `status-page.md` § Home reports in |
| `blackbox-exporter` | Probe target for `VMProbe` `https`/`icmp`/`tcp`. Also the wake signal for every zeroscaler app                                                                      |

## Alert plumbing (both clusters)

These facts apply to Artemis and Frostlink:

- `VMAlert.selectAllByDefault: true` evaluates every `VMRule`. This includes the ones that
  vm-operator converts from chart-shipped `PrometheusRule`s (kopiur on both clusters, towonel on
  Frostlink). Each cluster sets it in its own `vmalert.yaml`.
- kube-state-metrics runs with `honorLabels: true` (`kube/base/observability/kube-state-metrics/`).
  Without it, the target labels of the scrape (`namespace=observability`,
  `pod=kube-state-metrics-*`) overwrite the `namespace` and `pod` labels on every `kube_*` metric.
  Then alerts name the exporter, not the broken workload. `KubePodCrashLooping` once pointed at
  kube-state-metrics, but the pod in the crash loop was `matrix/mautrix-whatsapp`.

## Alert-rule choices that look like omissions

| Rule / silence                                                        | Why it is written that way                                                                                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No CNPG alert on `cnpg_pg_stat_archiver_seconds_since_last_archival`  | An idle database skips the WAL switch that `archive_timeout` forces. So the metric climbs past `archive_timeout` with nothing wrong. One cluster showed about 32m against a 900s timeout with zero failures. `cnpg_collector_pg_wal_archive_status{value="ready"} > 0` is the direct backlog signal and does not fire on a quiet cluster |
| `SmartDeviceMediaErrors` uses `delta()`, not `increase()`             | `smartctl_device_media_errors` is a gauge. `increase()` applies only to counters                                                                                                                                                                                                                                                         |
| `SmartDeviceAvailableSpareUnderThreshold` compares the two raw values | Both are percentages (spare 100, threshold 10), not 0–1 ratios, so no scaling is needed                                                                                                                                                                                                                                                  |
| Permanent `pantheon-memory-high` silence                              | `pantheon` (the Proxmox host) always runs at about 94%. This is a hardware limit, and nobody can act on it                                                                                                                                                                                                                               |

## Suppressing Bundled Chart Resources

Some charts (for example victoria-logs) always bundle GrafanaDashboards and have no flag to disable
one resource. To remove them, use a HelmRelease postRenderer:

```yaml
postRenderers:
    - kustomize:
          patches:
              - target:
                    kind: GrafanaDashboard
                    name: <dashboard-name>
                patch: |
                    $patch: delete
                    apiVersion: grafana.integreatly.org/v1beta1
                    kind: GrafanaDashboard
                    metadata:
                      name: <dashboard-name>
```

## kromgo Badge Metrics

The path is `/badges/<id>`, not `/<id>`. A bare `https://kromgo.dcunha.io/cluster_pod_count` returns
`404 page not found`. `https://kromgo.dcunha.io/badges/cluster_pod_count` returns the SVG. The root
path serves a gallery page that prints a Markdown snippet for each badge. Open it, and do not guess
an id.

The ids are in `kube/clusters/artemis/apps/observability/kromgo/app/resources/config.yaml`
(`grep -n 'id:' <that file>`):

| Group    | ids                                                                                                           |
| -------- | ------------------------------------------------------------------------------------------------------------- |
| Versions | `talos_version`, `kubernetes_version`, `flux_version`, `renovate_status`                                      |
| Cluster  | `cluster_node_count`, `cluster_pod_count`, `cluster_cpu_usage`, `cluster_memory_usage`, `cluster_alert_count` |
| Age      | `cluster_birth_age`, `cluster_uptime_age`                                                                     |
| Gatus    | `core_ping`, `core_status_page`, `core_heartbeat`, `internal_truenas`, `internal_pve`                         |

| Wrong (and what older docs said) | Right                |
| -------------------------------- | -------------------- |
| `cluster_age_days`               | `cluster_birth_age`  |
| `cluster_uptime_days`            | `cluster_uptime_age` |
| `https://kromgo.dcunha.io/<id>`  | `…/badges/<id>`      |

`?format=json` on the same path returns `{id,title,value,color,result}`. Use it to script a check,
so that you do not have to parse SVG.

kromgo renders the SVG itself. The repo README embeds those URLs directly
(`![Age](https://kromgo.dcunha.io/badges/cluster_birth_age)`), not shields.io endpoint URLs. The camo
proxy of GitHub caches a direct SVG for a long time. On GitHub mirrors, treat badge values as
approximate, and read live values from `?format=json`.

The badges that come from Gatus (`core_*`) depend on the Gatus of Frostlink, which
`vmstaticscrape-gatus.yaml` scrapes. `renovate_status` reads `kube_job_status_succeeded` in
`kube-system`. If its source stops reporting, each badge goes stale with no warning. The badge keeps
the colour of the last scraped value.

## Scrape coverage — where the holes are

`vmagent` reports every target healthy (`up == 0` returns nothing). But the healthy targets are only
the targets that exist. A namespace can run workloads that export metrics that nobody collects. Then
the alert rules that those workloads ship can never fire. Before you trust an alert in a namespace,
find out whether anything scrapes the namespace at all:

```bash
kubectl get vmservicescrape,vmpodscrape -n <namespace>
```

Known gaps: `cortex` hermes and most MCP servers (#1837).

### The `security` hole — a chart that ships rules and scrapes behind separate flags

`security/pocket-id-operator` ships alert rules, including `PocketIDOIDCClientRotationFailing`,
`PocketIDOIDCClientRotationOverdue` and `PocketIDExternalDeletions`. Every metric that they
reference was absent from VictoriaMetrics. So a client-secret rotation was able to fail for any length of
time with nothing firing.

To count the rules, run
`kubectl -n security get prometheusrule pocket-id-operator -o json | jq '[.spec.groups[].rules[]] | length'`.

The cause is a difference between two defaults in the values, not a missing manifest. In chart
0.14.0:

| Value                            | Default | Effect                                                              |
| -------------------------------- | ------- | ------------------------------------------------------------------- |
| `metrics.prometheusRule.enabled` | `true`  | rules render whenever the `monitoring.coreos.com/v1` CRD exists     |
| `metrics.enabled`                | `false` | operator starts with `--metrics-bind-address=0`. No metrics Service |
| `metrics.serviceMonitor.enabled` | `false` | no ServiceMonitor                                                   |

So the chart alerts by default and scrapes only when you turn it on. If you install it with no
change, it produces a PrometheusRule. Every expression in that rule queries a metrics server that
the same chart disabled. `kubectl get vmrule` looks healthy, but the rules do nothing. Any chart
that controls rules and scraping with different flags can do this. Before you trust an alert that
such a chart shipped, look at both flags.

The fix is to set `metrics.enabled: true` and `metrics.serviceMonitor.enabled: true` in
`security/pocket-id/operator/helmrelease.yaml`. That renders Service
`pocket-id-operator-metrics-service` on `:8080`, and a ServiceMonitor that the VM operator copies to
a VMServiceScrape.

The job label is the Service name. vmagent names service-scrape jobs after the Service, so the job
is `pocket-id-operator-metrics-service`. Because of this name, the two rules written as
`job=~".*pocket-id-operator.*"` match (`PocketIDReconcileErrors` and `PocketIDWorkQueueBackup`,
both on controller-runtime builtins). If a `jobLabel:` names a label that the Service does not
carry, vmagent ignores it with no warning, and the job falls back to the Service name. For that
reason, `grafana` in this cluster is job `grafana-service`.

### What actually exports metrics in `security`

| Workload             | Endpoint                               | Scrape                                            |
| -------------------- | -------------------------------------- | ------------------------------------------------- |
| `pocket-id-operator` | `:8080/metrics` once `metrics.enabled` | chart ServiceMonitor via `metrics.serviceMonitor` |
| `pocket-id`          | Service port `metrics` `:9464`         | `pocket-id/instance/servicemonitor.yaml` (ours)   |
| `lldap`              | none                                   | —                                                 |
| `tinyauth`           | none                                   | —                                                 |

lldap and tinyauth serve their SPA at `/metrics`. `wget -qO- :17170/metrics` returns
`<!doctype html>`, not metrics. There is nothing to scrape. Do not add monitors for them.

The pocket-id instance ServiceMonitor is hand-written. The chart template
`templates/instance/instance-servicemonitor.yaml` renders only when the chart owns the instance
(`instance.enabled`). This cluster deploys the `PocketIDInstance` itself from `pocket-id/instance/`,
so that template never renders. Its selector also does not match. It matches
`app.kubernetes.io/name` + `app.kubernetes.io/instance`, and the Service that the operator creates
carries only `managed-by: pocket-id-operator`. Our ServiceMonitor selects on that label.

### Finding the next dead alert

An alert whose metric has no scrape source produces no series. So compare the metric names in every
rule against the names that VictoriaMetrics knows:

```bash
kubectl port-forward -n observability svc/victoria-metrics-server 18428:8428 &
export LC_ALL=C
comm -23 \
  <(kubectl get vmrule -A -o json | jq -r '.items[].spec.groups[].rules[].expr' \
      | grep -oE '\b[a-z_][a-z0-9_]*_[a-z0-9_]+\b' | sort -u) \
  <(curl -s localhost:18428/api/v1/label/__name__/values | jq -r '.data[]' | sort -u)
```

`LC_ALL=C` is required, because `comm` rejects the collation of the default locale. The output
holds more than metric names. Label names (`pool_name`, `code_verb`), label values (`min_spacing`,
`window_missed`) and PromQL keywords with more than one word (`clamp_max`, `group_left`) all have
the same shape. Read the output as a list of candidates, not a verdict. A block of names from one
`<subsystem>_*` family is the real signal. The eleven `pocketid_operator_*` names formed such a
block. The other names are families that do not exist on this cluster, and their rules come from
vendored rule sets.

## chaski Notification Templates

`kube/clusters/artemis/apps/observability/chaski/app/helmrelease.yaml` renders every Pushover
notification. Four payload shapes reach it. `route-title`, `route-message` and `route-url` send
each shape to its templates in this order:

| Discriminator       | Sender                       | Templates   |
| ------------------- | ---------------------------- | ----------- |
| `payload.alerts`    | Alertmanager                 | `alert-*`   |
| `payload.eventType` | Sonarr / Radarr              | `arr-*`     |
| `payload.skill`     | hermes cron skills           | `hermes-*`  |
| (none)              | ad-hoc `{title,message,url}` | passthrough |

The order is load-bearing. The dispatch checks `skill` third. So an Alertmanager or arr payload
that also carries a `skill` key still takes its own branch. To add a fifth sender, add a branch at
the end. Never reorder the existing ones.

### Why the hermes branch is shaped the way it is

The two hermes skills (`cluster-health`, `readme-sync`) are LLM cron jobs. When they wrote their own
HTML message bodies, every run produced a slightly different layout: different labels, a different
order, and sometimes raw markdown. The fix is a strict split. The skill supplies data, and chaski
supplies the format. The skill POSTs `{skill, status, summary, stats{}, items[], url}` and nothing
else.

These results are on purpose:

- The title contains no payload text at all. `hermes-name` maps the skill slug to a fixed display
  name, and `hermes-status` maps the status to one of four fixed tokens. So the title is one of a
  small closed set, and nobody can inject text into it. Pushover never renders HTML in titles, so
  tags must stay out of the title.
- Every value from the model passes through `hermes-text`, `hermes-word`, `hermes-slug` or
  `hermes-num`. These apply `default` → `toString` → `trunc` → `html`. The `html` escaper is the
  text/template builtin. sprout has no equivalent, and `escapeHTML` and `htmlEscape` are not
  defined. Without the escaper, a stray `<` in a PR title breaks the `format: html` rendering of
  Pushover.
- The template checks the type of `stats` and `items` with `kindIs` before use. `dig` and field
  access both fail when a key holds the wrong type (for example `stats` as a string). If the render
  fails, chaski drops the notification. That is the case where you most want to hear from the job.
  The checks change a malformed value to an empty dict or list, so a degraded notification still
  arrives.
- Each field has its own length limit. There is no global limit, because truncating the composed
  body can cut a tag in half. The worst case (every field at its maximum, 12 items) renders at 861
  chars. The limit of Pushover is 1024.
- `hermes-url` drops anything that does not start with `https://`. So a hallucinated `javascript:`
  or internal URL never reaches the action button of the notification.
- An unknown skill slug renders an `Unknown Skill` frame and does not fail. If a new skill does not
  add its rows, it still notifies. The notification is visibly wrong, not silent.

### Changing a template

Before you commit, make sure offline that the template works. chaski checks how its snippets
connect at boot. So a typo in a `{{ template }}` name takes the whole deployment down:

```bash
podman run --rm -v "$PWD:/c:z" ghcr.io/home-operations/chaski:latest \
  validate -c /c/chaski.yaml --payload /c/sample.json --route warning
```

`chaski.yaml` is `spec.values.config`, taken out of the HelmRelease, with the apprise URL replaced
by `json://localhost/`. Render a sample for all four payload shapes. All shapes share one dispatch
template, so a hermes edit can break the alertmanager output.

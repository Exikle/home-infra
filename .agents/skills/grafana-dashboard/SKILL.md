---
name: grafana-dashboard
description: Add or fix a Grafana dashboard via the GrafanaDashboard CRD — datasource wiring, variable escaping, and the folder/label selectors the operator needs. Use for "add a Grafana dashboard", "GrafanaDashboard CRD", "$$variable not working", or "datasource panels are empty". Scoped to the Artemis cluster.
compatibility: Requires the Grafana Operator and its CRDs. Dashboards are CRs, never ConfigMaps or HelmRelease values.
---

# Skill: Grafana Dashboard

You create and manage Grafana resources through the Grafana Operator. They are CRs, not ConfigMaps
or HelmRelease values.

> Also read `.agents/references/observability.md` before you work on dashboards. Edit in a
> worktree. Run `mise run //:wt:new feat/<slug>` first (`AGENTS.md` rule 7).

## All Resources Use `grafana.integreatly.org/v1beta1`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard # or GrafanaDatasource, GrafanaFolder, GrafanaAlertRuleGroup
```

Kinds are case-sensitive. The datasource kind is `GrafanaDatasource`, with a lowercase `s`. To list
every kind in the group, run `kubectl api-resources --api-group=grafana.integreatly.org`.

## Instance Selector (required on every resource)

```yaml
spec:
    instanceSelector:
        matchLabels:
            dashboards: grafana
```

To make sure that the label is exact, run this command:

```bash
kubectl get grafana -n observability -o yaml | grep -A5 "labelSelector\|dashboards"
```

## Namespace = Folder

The namespace of a `GrafanaDashboard` sets the Grafana folder that it appears in. Deploy dashboards
in the app's own namespace, not in `observability` or `default`.

```yaml
metadata:
    name: miroir-overview
    namespace: miroir-system # → appears in "miroir-system" folder in Grafana
```

## Datasource Names

A dashboard refers to a datasource by its `spec.datasource.name`, not by the name of the CR. A
wrong name gives empty panels and no error. The two names differ for two datasources. For example,
the CR `victoria-logs` has the datasource name `VictoriaLogs`.

Before you write a dashboard, list the real names:

```bash
kubectl get grafanadatasource -A \
  -o custom-columns=CR:.metadata.name,NAME:.spec.datasource.name,TYPE:.spec.datasource.type
```

Use the `NAME` column. `observability.md` § `datasourceName` is the CR's `spec.datasource.name`,
not the CR's own name has the table and the reasons. That file wins.

## CRITICAL: Escape All Grafana Variables

You must double every `$` in dashboard JSON to `$$`. The operator treats a single `$` as a Go
template variable. It silently replaces it with an empty string.

```json
{ "expr": "rate(http_requests_total{job=$$job}[$$__rate_interval])" }
```

Common tokens to double:

- `$$__rate_interval`, `$$__range`, `$$__interval`
- `$$job`, `$$namespace`, `$$pod`, `$$node`
- `$$__from`, `$$__to`

## GrafanaDashboard Template

Grafana runs in `observability`. A dashboard in any other namespace needs
`allowCrossNamespaceImport: true` as the first key under `spec`. If it is missing, the operator
never imports the dashboard. For a dashboard that you fetch with `url:` or `configMapRef:`, bind
the panels with `spec.datasources[]`. Each entry has a `datasourceName` and the `inputName` that
the JSON declares. See `kube/clusters/artemis/apps/observability/grafana/app/grafanadashboard.yaml`.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
    name: <app>-overview
    namespace: <app-namespace>
spec:
    allowCrossNamespaceImport: true
    instanceSelector:
        matchLabels:
            dashboards: grafana
    json: |
        {
          "title": "<App> Overview",
          "uid": "<app>-overview",
          "panels": [...]
        }
```

## GrafanaDatasource Template

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
    name: <name>
    namespace: <namespace>
spec:
    instanceSelector:
        matchLabels:
            dashboards: grafana
    datasource:
        name: <name>
        type: prometheus
        url: http://<service>.<namespace>.svc.cluster.local:<port>
        editable: true
        isDefault: false
```

`editable: true` is required, because the Grafana Operator makes datasources read-only by default.

## Suppressing Bundled Chart Dashboards

Some charts always include GrafanaDashboards. Remove them with a postRenderer:

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

## Common Issues

| Symptom                                  | Cause                                                                                          | Fix                                                                      |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Dashboard exists but panels show no data | Single `$` instead of `$$` in the query, or a CR name used as `datasourceName`                 | Double all `$` tokens. Use the `NAME` column from § Datasource Names     |
| Dashboard in wrong folder                | Deployed in the wrong namespace                                                                | Move it to the correct namespace. Remove the old copy from git           |
| Dashboard not appearing in Grafana       | Wrong `instanceSelector` label, or `allowCrossNamespaceImport` missing outside `observability` | Read the label with `kubectl get grafana -n observability`. Add the flag |
| Datasource fields all empty              | `editable: true` missing                                                                       | Add `editable: true` to the datasource spec                              |
| Old dashboard overriding new             | Stale copy in the `default` namespace                                                          | Remove it from git. If git does not manage it, ask the user to delete it |

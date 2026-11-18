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

The namespace of a `GrafanaDashboard` sets its Grafana folder. Deploy it in the namespace of the
app. `observability.md` § Grafana Operator has the rule, and it wins.

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

## Flux substitution and `$` in dashboard JSON

Flux variable substitution can blank the variables in dashboard JSON. If the JSON sits inline in a
manifest, and the Kustomization of the app has `postBuild`, Flux replaces each `${...}` token after
the build. A Grafana token such as `${__rate_interval}` then becomes an empty string, with no
error.

Do one of these things:

1. Load the JSON with `url:` or `configMapRef:`. Every dashboard in this repo does this.
2. If the JSON must be inline, set the annotation `kustomize.toolkit.fluxcd.io/substitute: disabled`
   on the `GrafanaDashboard`.

## GrafanaDashboard Template

Grafana runs in `observability`. A dashboard in any other namespace needs
`allowCrossNamespaceImport: true` as the first key under `spec`. If it is missing, the operator
never imports the dashboard. Bind the panels with `spec.datasources[]`. Each entry has a
`datasourceName` and the `inputName` that the JSON declares. Do not add `namespace:` to metadata.
The `targetNamespace` of the Flux Kustomization injects it. This template copies
`kube/clusters/artemis/apps/observability/grafana/app/grafanadashboard.yaml`:

```yaml
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
    name: <app>-overview
spec:
    allowCrossNamespaceImport: true
    instanceSelector:
        matchLabels:
            dashboards: grafana
    datasources:
        - datasourceName: prometheus
          inputName: DS_PROMETHEUS
    url: https://grafana.com/api/dashboards/<id>/revisions/<revision>/download
```

For JSON that you keep in the repo, replace `url:` with a `configMapRef:` (`name` and `key`) to a
generated ConfigMap.

## GrafanaDatasource Template

This template copies
`kube/clusters/artemis/apps/observability/grafana/instance/grafanadatasource.yaml`:

```yaml
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
    name: <name>
spec:
    instanceSelector:
        matchLabels:
            dashboards: grafana
    datasource:
        type: prometheus
        name: <name>
        access: proxy
        url: http://<service>.<namespace>.svc.cluster.local:<port>
```

## Suppressing Bundled Chart Dashboards

Some charts always include GrafanaDashboards. Remove them with a HelmRelease postRenderer.
`observability.md` § Suppressing Bundled Chart Resources has the block, and it wins.

## Common Issues

| Symptom                                  | Cause                                                                                          | Fix                                                                                              |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Dashboard exists but panels show no data | Flux substituted a `${...}` token in inline JSON, or a CR name used as `datasourceName`        | See § Flux substitution and `$` in dashboard JSON. Use the `NAME` column from § Datasource Names |
| Dashboard in wrong folder                | Deployed in the wrong namespace                                                                | Move it to the correct namespace. Remove the old copy from git                                   |
| Dashboard not appearing in Grafana       | Wrong `instanceSelector` label, or `allowCrossNamespaceImport` missing outside `observability` | Read the label with `kubectl get grafana -n observability`. Add the flag                         |
| Old dashboard overriding new             | Stale copy in the `default` namespace                                                          | Remove it from git. If git does not manage it, ask the user to delete it                         |

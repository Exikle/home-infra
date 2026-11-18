# Module: ks.yaml Template

The spec field order is in `.agents/instructions/yaml-conventions.md` § ks.yaml.

Frostlink uses Kopiur in a different way:

1. Add `dependsOn` for `kopiur-repository` (namespace `kopiur-system`).
2. Use `../../../../components/kopiur` (no `/backup`).
3. Set `KOPIUR_APP: *app` under `postBuild.substitute`.

The component owns the PVC, so do not declare one. Every `KOPIUR_*` substitution except
`KOPIUR_APP` has a default (`KOPIUR_CAPACITY` is `5Gi`). The defaults are in
`kube/clusters/frostlink/components/kopiur/`. For a periodic full restore check, add
`../../../../components/kopiur-deep-verify` and `KOPIUR_DEEP_VERIFY_CAPACITY`. Paths use
`kube/clusters/frostlink/apps/<ns>/<app>/`. The Frostlink `wait` and `healthChecks` placement
is as in `kube/clusters/frostlink/apps/fediverse/gotosocial/ks.yaml`.

## Minimal (no persistence, no secrets)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: &app <app>
spec:
    targetNamespace: <namespace>
    commonMetadata:
        labels:
            app.kubernetes.io/name: *app
    path: ./kube/clusters/<cluster>/apps/<namespace>/<app>/app
    prune: true
    sourceRef:
        kind: OCIRepository
        name: flux-system
        namespace: flux-system
    interval: 1h
    wait: true
```

## With ExternalSecret (add to dependsOn)

```yaml
dependsOn:
    - name: onepassword-connect
      namespace: external-secrets
```

## With kopiur backup (add components + postBuild)

```yaml
components:
    - ../../../../components/kopiur/backup
postBuild:
    substitute:
        APP: *app
        KOPIUR_CAPACITY: 5Gi
```

A Kustomization with kopiur sets `wait: false`. With `wait: true`, the kopiur `SnapshotSchedule`
stalls the health checks (`.agents/references/flux-patterns.md` § kopiur CRs stall `wait: true`
health checks). If a dependent must wait for the app, add `healthChecks` on the HelmRelease.

## With scale-to-zero (add to components)

```yaml
components:
    - ../../../../components/zeroscaler
```

## With shared Postgres (add components + postBuild)

```yaml
components:
    - ../../../../components/postgres/app
postBuild:
    substitute:
        APP: *app
```

## Full example (storage + secrets + kopiur)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: &app <app>
spec:
    targetNamespace: <namespace>
    commonMetadata:
        labels:
            app.kubernetes.io/name: *app
    path: ./kube/clusters/<cluster>/apps/<namespace>/<app>/app
    prune: true
    sourceRef:
        kind: OCIRepository
        name: flux-system
        namespace: flux-system
    interval: 1h
    dependsOn:
        - name: onepassword-connect
          namespace: external-secrets
    components:
        - ../../../../components/kopiur/backup
    postBuild:
        substitute:
            APP: *app
            KOPIUR_CAPACITY: 5Gi
    wait: false
```

## Components

`ls kube/clusters/artemis/components` lists them. The substitutions of a component are the
`${...}` references in its own files (`grep -rho '\${[A-Z_]*' kube/clusters/artemis/components/<name>`).
`grep -rln 'components/<name>' kube/clusters/artemis/apps/` shows which apps use it, with a
working example. `kopiur/backup` renders a PVC, a `Restore`, a `SnapshotPolicy` and a
`SnapshotSchedule`. `envoy-oidc` needs `pocket-id-operator` in `dependsOn` and an
`oidcclient.yaml` (see `add-oidc-app`).

All paths sit four `../` from `kube/clusters/artemis/apps/<ns>/<app>/`. A wrong count is the most
common failure here. `../../../` resolves outside the kustomize root, and the build fails with an
error. Components stack.

## Notes

- YAML blocks in these templates render at 4-space indent, but real manifests use 2 spaces. Copy
  the structure, not the indentation (`yaml-conventions.md` § What the tooling does for you).
- Use the YAML anchor `&app` on `metadata.name`. Use the alias `*app` everywhere that the app name
  repeats (labels, postBuild).
- Always include `namespace:` on every cross-namespace `dependsOn` entry. If you omit it, the entry
  silently resolves to the local namespace.
- `retryInterval` and `timeout` are optional. Add them only when the app is known to be slow to
  reconcile.
- `healthChecks` goes last, after `wait`. Only a small number of apps need it. One example is a
  CRD-bearing operator whose dependents must not start until a named object exists.

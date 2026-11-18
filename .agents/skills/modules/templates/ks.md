# Module: ks.yaml Template

The spec field order is in `.agents/instructions/yaml-conventions.md` § ks.yaml. It is the same on
both clusters, and the `yaml-order` hook enforces it on both.

Frostlink uses Kopiur in a different way:

1. Use `../../../../components/kopiur` (no `/backup`).
2. Set `KOPIUR_APP: *app` under `postBuild.substitute`.
3. Set `wait: false` and gate on `healthChecks`, as on Artemis (§ With kopiur backup).

The component owns the PVC, so do not declare one. Every `KOPIUR_*` substitution except
`KOPIUR_APP` has a default (`KOPIUR_CAPACITY` is `5Gi`). The defaults are in
`kube/clusters/frostlink/components/kopiur/`. For a periodic full restore check, add
`../../../../components/kopiur-deep-verify` and `KOPIUR_DEEP_VERIFY_CAPACITY`.

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
        KOPIUR_CAPACITY: <size>
```

Set `KOPIUR_CAPACITY` only when the size is not `5Gi`. The component defaults it to `5Gi`
(`yaml-conventions.md` § No Restating Defaults).

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
            KOPIUR_CAPACITY: <size>
    wait: false
```

## Components

`ls kube/clusters/<cluster>/components` lists them. The substitutions of a component are the
`${...}` references in its own files
(`grep -rho '\${[A-Z_]*' kube/clusters/<cluster>/components/<name>`).
`grep -rln 'components/<name>' kube/clusters/<cluster>/apps/` shows which apps use it, with a
working example. `kopiur/backup` renders a PVC, a `Restore`, a `SnapshotPolicy` and a
`SnapshotSchedule`. `envoy-oidc` needs `pocket-id-operator` in `dependsOn` and an
`oidcclient.yaml` (see `add-oidc-app`).

Two Artemis components also need a component in the namespace `kustomization.yaml`:

- `kopiur/backup` needs `../../components/kopiur/secret` (`.agents/references/kopiur.md` § kopiur).
- `postgres/app` needs `../../components/postgres/tenants` (`postgres-dragonfly.md` § Onboarding
  an app onto shared Postgres).

Component paths are relative to `spec.path`, which is `<app>/app/`. Four `../` from there reaches
`kube/clusters/<cluster>/components/`. A wrong count is the most common failure here. With three
`../`, the path points at `apps/components`, which does not exist, and the build fails. Components
stack.

## Notes

- Copy the structure of these blocks, not the indentation (`yaml-conventions.md` § What the
  tooling does for you).
- Use the YAML anchor `&app` on `metadata.name`. Use the alias `*app` everywhere that the app name
  repeats (labels, postBuild).
- Always include `namespace:` on every cross-namespace `dependsOn` entry. If you omit it, the entry
  silently resolves to the local namespace.
- Set `wait: true` when another Kustomization `dependsOn` this one and needs its objects Ready.
  Set `wait: false` otherwise, and always with kopiur.
- The root injects `retryInterval: 1m` into every child (`flux-patterns.md` § Key Rules). Set
  `retryInterval` only to override it. Set `timeout` only when the app is known to be slow to
  reconcile.
- `healthChecks` goes last, after `wait`. Only a small number of apps need it. One example is a
  CRD-bearing operator whose dependents must not start until a named object exists.

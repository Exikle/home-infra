# Module: ks.yaml Template

Field order: `yaml-conventions.md` § ks.yaml. It does not list `wait` or `healthChecks`: in the
tree `wait: true` (optional, about half the apps) sits right after `interval`/`retryInterval`/`timeout`
and usually before `dependsOn` (a few ks.yaml put it after), and `healthChecks` sits right after `interval`
(`kubernetes/apps/fediverse/gotosocial/ks.yaml`, `network/headscale/ks.yaml`).

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
    path: ./kubernetes/apps/<namespace>/<app>/app
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

## With Kopiur backup (add dependsOn, components, postBuild)

The `kopiur` component owns the PVC, so do not also declare one. Every `KOPIUR_*` substitution
except `KOPIUR_APP` has a default (`KOPIUR_CAPACITY` defaults to `5Gi`) (`kubernetes/components/kopiur/`).

```yaml
dependsOn:
    - name: kopiur-repository
      namespace: kopiur-system
components:
    - ../../../../components/kopiur
postBuild:
    substitute:
        APP: *app
        KOPIUR_APP: *app
        KOPIUR_CAPACITY: 5Gi
```

Add `../../../../components/kopiur-deep-verify` (and `KOPIUR_DEEP_VERIFY_CAPACITY`) when the
data is worth a periodic full restore check. Rules for `dependsOn` namespaces and the rest:
`flux-patterns.md` § flate `dependsOn` Namespace, `cluster-conventions.md`.

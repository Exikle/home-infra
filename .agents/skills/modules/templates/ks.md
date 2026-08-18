# Module: ks.yaml Template

Spec field order: `targetNamespace → commonMetadata → path → prune → sourceRef → interval → retryInterval → timeout → dependsOn → components → postBuild → wait`

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

## With Kopiur backup (add dependsOn + components + postBuild)

There is no Rook-Ceph and no VolSync on this cluster. PVCs are `openebs-zfs`, and backups go to
Cloudflare R2 via Kopiur. The `kopiur` component owns the PVC itself — do not also declare one.

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

Add `../../../../components/kopiur-deep-verify` (with `KOPIUR_DEEP_VERIFY_CAPACITY`) when the
app's data is worth a periodic full restore check. Other `KOPIUR_*` substitutions all have
defaults — see `kubernetes/components/kopiur/`.

## Full example (storage + secrets + Kopiur)

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
    dependsOn:
        - name: onepassword-connect
          namespace: external-secrets
        - name: kopiur-repository
          namespace: kopiur-system
    components:
        - ../../../../components/kopiur
    postBuild:
        substitute:
            APP: *app
            KOPIUR_APP: *app
            KOPIUR_CAPACITY: 5Gi
    wait: true
```

## Notes

- Use YAML anchor `&app` on `metadata.name` and alias `*app` everywhere the app name repeats (labels, postBuild).
- Always include `namespace:` on every cross-namespace `dependsOn` entry — omitting it silently resolves to the local namespace.
- `sourceRef.kind` is `OCIRepository` — this repo syncs from an OCI artifact, not a GitRepository.
- `retryInterval` and `timeout` are optional — add only when the app is known to be slow to reconcile.

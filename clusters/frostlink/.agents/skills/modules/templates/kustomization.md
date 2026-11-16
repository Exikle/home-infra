# Module: app/kustomization.yaml Template

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - ./helmrelease.yaml
    - ./ocirepository.yaml
```

Resources are alphabetical. App-template apps define secrets inline in the HelmRelease
(`externalsecret.md`), so there is no `externalsecret.yaml`. Some apps also set `namespace:`; the
tree is split, so follow the other apps in the target namespace.

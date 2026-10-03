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

## Notes

- `apiVersion` is always `kustomize.config.k8s.io/v1beta1` — `v1` does not exist for this kind.
- No `externalsecret.yaml`: app-template apps define secrets inline in the HelmRelease — see
  `externalsecret.md`.
- Resources are listed alphabetically.

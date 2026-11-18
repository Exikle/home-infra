# Module: app/kustomization.yaml Template

The template is the same on both clusters. A few apps on each cluster also set `namespace:`.
Follow the other apps in the target namespace.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - ./helmrelease.yaml
    - ./ocirepository.yaml
```

There is no `./externalsecret.yaml`. app-template apps define secrets inline in the HelmRelease.
See `externalsecret.md`.

## With a config file the app reads from disk

Several apps need a real file mounted, not env vars. Generate the file. Do not hand-write a
ConfigMap. Turn off Flux variable substitution on it, so that a `$` in the payload survives:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
    - ./helmrelease.yaml
    - ./ocirepository.yaml
configMapGenerator:
    - name: <app>-config
      files:
          - config.yaml=./resources/config.yaml
generatorOptions:
    disableNameSuffixHash: true
    annotations:
        kustomize.toolkit.fluxcd.io/substitute: disabled
```

## Notes

- Copy the structure of these blocks, not the indentation (`yaml-conventions.md` § What the
  tooling does for you).
- `apiVersion` is always `kustomize.config.k8s.io/v1beta1`. `v1` does not exist for this kind.
- The schema URL is the `k8s-schemas.home-operations.com` one on both clusters. The `k8s-schema`
  pre-commit hook (`hk.pkl`, configured by `.k8s-schema-hook.yaml`) writes it. If you write
  `https://json.schemastore.org/kustomization`, the hook rewrites it at your first commit.
- `resources` is sorted alphabetically, as `yaml-conventions.md` says, not in deployment order.
- A generated ConfigMap whose payload contains `${...}` must have
  `generatorOptions.annotations.kustomize.toolkit.fluxcd.io/substitute: disabled`. Without it, the
  `postBuild` substitution of Flux removes the value, and the app gets an empty value.

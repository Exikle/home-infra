# Module: OCIRepository Template

The template is the same on both clusters. The rules for the chart (the `bjw-s-labs` URL, the `v1`
API, a bare chart tag, one OCIRepository per app) are in `cluster-conventions.md` § Helm /
app-template, which wins.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
    name: <app>
spec:
    interval: 15m
    layerSelector:
        mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
        operation: copy
    ref:
        tag: <app-template version>
    url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

## Notes

- `name` must match the app name, because `chartRef.name` in the HelmRelease references it.
- `ref.tag` is the version of the app-template chart, not the tag of the app image.
- Do not add `namespace:` to metadata. The `targetNamespace` of the Flux Kustomization injects it.

## Values that drift: recover them from the tree

Renovate bumps `ref.tag` across the whole fleet, so a number written here goes stale by design.
This command prints the current app-template tag of one cluster. It reads only the
OCIRepositories that point at app-template, because Frostlink also has many other charts:

```bash
grep -l 'bjw-s-labs/helm/app-template' kube/clusters/<cluster>/apps/*/*/app/ocirepository.yaml | xargs grep -h 'tag:' | sort | uniq -c | sort -rn | head -1
```

The usual `interval` is `15m` on both clusters.

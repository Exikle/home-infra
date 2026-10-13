# Module: OCIRepository Template

One standalone OCIRepository per app, named after the app (`chartRef.name` points at it).

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
    name: <app>
spec:
    interval: 1h
    layerSelector:
        mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
        operation: copy
    ref:
        tag: <app-template-tag>
    url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

`<app-template-tag>` is the chart version, bare (no digest). Match the tag the other apps use:

```bash
grep -rh 'tag:' kubernetes/apps/*/*/app/ocirepository.yaml | sort | uniq -c
```

Rules (`url` org, `v1`, no `namespace:`) are in `cluster-conventions.md` and checked by `checklists/ocirepository.md`.

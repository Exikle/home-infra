# Module: HelmRelease Template

The schema line below is the one that the `k8s-schema` hook writes for app-template, on both
clusters. A chart that is not app-template uses
`https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json`.

Field order is in `.agents/instructions/yaml-conventions.md`, on both clusters. `postRenderers`
is last, and it is easy to forget. Only a couple of apps use it
(`.agents/references/observability.md`).

Frostlink: the route uses `external-gateway` in `namespace: network`, the only gateway there. The
gateway table below is for Artemis.

## Minimal template

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
    name: <app>
spec:
    chartRef:
        kind: OCIRepository
        name: <app>
    interval: 1h
    values:
        defaultPodOptions:
            securityContext:
                fsGroup: 1000
                fsGroupChangePolicy: OnRootMismatch
                runAsGroup: 1000
                runAsNonRoot: true
                runAsUser: 1000
        controllers:
            <app>:
                annotations:
                    reloader.stakater.com/auto: "true"
                containers:
                    app:
                        image:
                            repository: <image-repo>
                            tag: <tag>@sha256:<digest>
                        probes:
                            liveness:
                                enabled: true
                            readiness:
                                enabled: true
                        resources:
                            requests:
                                cpu: 10m
                                memory: 128Mi
                            limits:
                                memory: 512Mi
                        securityContext:
                            allowPrivilegeEscalation: false
                            capabilities:
                                drop:
                                    - ALL
                            readOnlyRootFilesystem: true
        persistence:
            data:
                existingClaim: <app>
                globalMounts:
                    - path: /data
            tmp:
                type: emptyDir
                advancedMounts:
                    <app>:
                        app:
                            - path: /tmp
                              subPath: tmp
        route:
            app:
                hostnames:
                    - <hostname>
                parentRefs:
                    - name: internal-gateway
                      namespace: network
        service:
            app:
                ports:
                    http:
                        port: <port>
```

## Gateways: pick by hostname suffix

These are the Artemis gateways:

| Gateway            | Hostnames                        | Exposure                                      |
| ------------------ | -------------------------------- | --------------------------------------------- |
| `internal-gateway` | `*.dcunha.io`                    | LAN only                                      |
| `edge-gateway`     | `*.frostlink.dev`, `*.dcunha.io` | Public via towonel (and LAN); `:80` redirects |
| `external-gateway` | —                                | Legacy, no routes. Do not use on Artemis      |

All three live in `namespace: network`. Every public app goes on `edge-gateway`, whichever
domain. A `*.dcunha.io` route there must not pin `sectionName: https`, because that is the
`frostlink.dev` listener. Use `https-dcunha` or omit it. To give an app a second hostname,
add a second named route:

```yaml
route:
    app:
        hostnames:
            - <app>.dcunha.io
        parentRefs:
            - name: edge-gateway
              namespace: network
    frostlink:
        hostnames:
            - <app>.frostlink.dev
        parentRefs:
            - name: edge-gateway
              namespace: network
```

Details, the listener table and the towonel origin mapping: `.agents/references/towonel-agent.md`
(wins over this table).

## Notes

The shared rules for app-template apps (no `TZ`, the reloader annotation, routes inline, no
comments in manifests, field order) are in `cluster-conventions.md` and `yaml-conventions.md`.
Those files win. These notes are only about this template:

- Do not add `namespace:` to metadata. The `targetNamespace` of the Flux Kustomization injects it.
- `fsGroup: 1000` is needed only when the app uses a PVC.
- `readOnlyRootFilesystem: true` requires a `tmp` emptyDir entry. Use `advancedMounts` with
  `subPath`, even for a single path.
- Remove the `persistence` block entirely if the app has no PVC and no writable paths.
- Remove the `route` block if no ingress is needed.
- Omit the `startup` probe unless the app is slow to start. app-template turns every probe off
  unless you set `enabled: true`.

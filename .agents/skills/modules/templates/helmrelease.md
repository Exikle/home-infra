# Module: HelmRelease Template

Field order: `yaml-conventions.md`. Conventions (security context, probes, no `TZ`, reloader
annotation, routes inline): `cluster-conventions.md` § Helm / app-template v5.

Replace `<app-template-tag>` with the tag in the app's `ocirepository.yaml`
(`templates/ocirepository.md` shows how to find it).

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/app-template-<app-template-tag>/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
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
                    - name: external-gateway
                      namespace: network
        service:
            app:
                ports:
                    http:
                        port: <port>
```

- `persistence.data` and `fsGroup` assume the `kopiur` component in `ks.yaml` creates the PVC
  `<app>` (`ks.md`). For a stateless app drop `data` and `fsGroup`.
- Drop `route` if the app has no ingress. Drop `tmp` only if the root filesystem is writable.
- No `namespace:` in metadata — the Kustomization's `targetNamespace` injects it.

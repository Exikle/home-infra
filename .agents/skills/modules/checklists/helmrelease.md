# Checklist: app/helmrelease.yaml

Mark each item PASS, FAIL, or N/A.

H30 to H32 are Artemis items. On Frostlink, the only gateway is `external-gateway`. A route there
has `parentRefs` on `external-gateway` with `namespace: network`. Frostlink has no internal
gateway. On Frostlink, the field order follows `.agents/instructions/frostlink.md` and
`.agents/skills/modules/checklists/yaml-sorting.md`.

An app-template app defines its route inline, under `route.app:` in its values. Only an app with
no app-template HelmRelease uses a standalone `httproute.yaml`. This applies to both clusters.
`.agents/instructions/cluster-conventions.md` has the rule and wins.

## Structure & schema

| #   | Check                                                                                                                                                                                                             | Result |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| H1  | Schema comment present: the bjw-s `helmrelease-helm-v2.schema.json` URL for app-template, or `https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json` for other charts. Either passes |        |
| H2  | `apiVersion: helm.toolkit.fluxcd.io/v2`                                                                                                                                                                           |        |
| H3  | `chartRef.kind: OCIRepository`, `chartRef.name: <app>` (references own OCIRepository)                                                                                                                             |        |
| H4  | `interval: 1h`                                                                                                                                                                                                    |        |
| H5  | `spec` field order per `yaml-conventions.md` § HelmRelease (`postRenderers` last)                                                                                                                                 |        |

## spec.values ordering

| #   | Check                                                                   | Result |
| --- | ----------------------------------------------------------------------- | ------ |
| H6  | `defaultPodOptions` is the first key in `spec.values` (if present)      |        |
| H7  | All other `spec.values` keys are alphabetical after `defaultPodOptions` |        |

## defaultPodOptions

> PUID/PGID exception: if the container has `PUID`/`PGID` env vars, the image is Linuxserver-style. It starts as root to create its own user. Mark H8/H9/H10 as N/A. Do not set `runAsNonRoot`, `runAsUser`, or `runAsGroup`, because the entrypoint handles user switching. See advisory A19.

| #   | Check                                                                      | Result |
| --- | -------------------------------------------------------------------------- | ------ |
| H8  | `securityContext.runAsNonRoot: true` (N/A for PUID/PGID images, see above) |        |
| H9  | `securityContext.runAsUser: 1000` (N/A for PUID/PGID images, see above)    |        |
| H10 | `securityContext.runAsGroup: 1000` (N/A for PUID/PGID images, see above)   |        |
| H11 | `securityContext.fsGroup: 1000` present when app uses a PVC                |        |
| H12 | `securityContext.fsGroupChangePolicy: OnRootMismatch`                      |        |

## Controllers

| #   | Check                                                                                                                                                               | Result |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| H13 | Controller has annotation `reloader.stakater.com/auto: "true"`                                                                                                      |        |
| H14 | Controller field order: `enabled → type → annotations → labels → <controller-specific> → pod → initContainers → containers`. `enabled` is first wherever it appears |        |

## Containers

| #   | Check                                                                                                                 | Result |
| --- | --------------------------------------------------------------------------------------------------------------------- | ------ |
| H15 | `image` is the first field in every container block                                                                   |        |
| H16 | `env.TZ` is not set, because k8tz injects the timezone cluster-wide (always N/A)                                      |        |
| H17 | `probes.liveness.enabled` is present                                                                                  |        |
| H18 | `probes.readiness.enabled` is present                                                                                 |        |
| H19 | `resources.requests` present (`cpu` and `memory`)                                                                     |        |
| H20 | `resources.limits.memory` present                                                                                     |        |
| H21 | `resources.requests` comes before `resources.limits`                                                                  |        |
| H22 | `securityContext.allowPrivilegeEscalation: false` (N/A for PUID/PGID images)                                          |        |
| H23 | `securityContext.readOnlyRootFilesystem: true` (N/A for PUID/PGID images and Chrome/Chromium-based apps, see A19/A20) |        |
| H24 | `securityContext.capabilities.drop: [ALL]` (N/A for PUID/PGID images)                                                 |        |
| H25 | Container field order: `image` first, then alphabetical                                                               |        |

## Persistence

| #    | Check                                                                                                          | Result |
| ---- | -------------------------------------------------------------------------------------------------------------- | ------ |
| H26  | If the app uses kopiur: `existingClaim: <app>` (not an inline PVC spec)                                        |        |
| H27  | If `readOnlyRootFilesystem: true`: a `tmp` emptyDir mount exists                                               |        |
| H27a | Every emptyDir uses `advancedMounts` (never `globalMounts`), with a `subPath` per path, even for a single path |        |
| H28  | Persistence item field order: `type → annotations → labels → <alphabetical> → globalMounts → advancedMounts`   |        |

## Service

| #   | Check                                                                                                               | Result |
| --- | ------------------------------------------------------------------------------------------------------------------- | ------ |
| H29 | Service item field order: `type → annotations → labels → <alphabetical> → ports`. `ports` is last, not alphabetical |        |

## Route

| #   | Check                                                                                                                                                                                                                                                                                                                                                                                                 | Result |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| H30 | If route present: `parentRefs` references `internal-gateway` (LAN-only) or `edge-gateway` (public), always with `namespace: network`. A new route on `external-gateway` is a FAIL (legacy, no upstream)                                                                                                                                                                                               |        |
| H31 | An app-template app defines its route under `route.app:` in values. A standalone `httproute.yaml` is a FAIL for an app-template app, and N/A for an app with no app-template HelmRelease                                                                                                                                                                                                              |        |
| H32 | Hostname and listener match. `*.frostlink.dev` goes only on `edge-gateway` (`sectionName: https` or none). `*.dcunha.io` goes on `internal-gateway`, or on `edge-gateway` with `sectionName: https-dcunha` or none. The apex `dcunha.io` goes on `edge-gateway` with `https-dcunha-apex`. A `*.dcunha.io` route on `edge-gateway` pinned to `sectionName: https` is a FAIL, because it never attaches |        |

Gateways, listeners and which hostname goes where: `templates/helmrelease.md` § Gateways, and
`.agents/references/towonel-agent.md` § Which gateway a route uses (wins).

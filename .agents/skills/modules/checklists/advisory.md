# Checklist: Advisory

These items are recommendations that need judgment. They are not hard convention violations. Mark
each item RECOMMEND, SKIP (not applicable), or N/A (you cannot decide without more context).

Put the findings in the `### ADVISORY` section of the report, apart from FAIL and WARN. Never
auto-fix an advisory item. A human must review it.

Frostlink differences:

- A3: the StorageClass is `openebs-zfs`. `miroir` does not exist there.
- A10: the only gateway is `external-gateway`, so any route is public. If nothing sits in front of
  the route (a SecurityPolicy or an app login), flag it. Make sure that this is intentional.
- A18: the scrape object is a `VMServiceScrape` or a `ServiceMonitor`. Use `--context frostlink`
  for any `kubectl`.

---

## Storage & Data Layer

| #   | Check                                                                                                                                                                                                                                                                                                                                               |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | The data store of the app has no stated reason. Either choice is fine: shared CNPG, or SQLite for a workload with one writer and low concurrency. The choice must be a decision, not a default. Flag only an unexplained per-app database, or an app moved onto Postgres with no reason given. This is not a recommendation to move back to SQLite. |
| A2  | The app has a PVC but no kopiur component in `ks.yaml`. The data has no backup. Recommend kopiur.                                                                                                                                                                                                                                                   |
| A3  | A StorageClass other than `miroir` or `miroir-local` is named. Those two are the only StorageClasses that exist.                                                                                                                                                                                                                                    |
| A4  | The app uses NFS for its own data store (not for shared media). Recommend a `miroir` PVC with `components/kopiur/backup`.                                                                                                                                                                                                                           |

---

## Reliability

| #   | Check                                                                                                                                                                                                                               |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A6a | The probe paths are weak. The probes hit `/`, not a dedicated `/ping`, `/health`, or `/healthz` endpoint. This is noisy and can hide real failures.                                                                                 |
| A7  | Do not flag a `ks.yaml` that has no `retryInterval`. The root Kustomization injects `retryInterval: 1m` on both clusters. Flag a `ks.yaml` that overrides it with a long value (`.agents/references/flux-patterns.md` § Key Rules). |
| A8  | The `dependsOn` chain looks incomplete. Make sure that the real dependencies of the app (storage, secrets, CNPG) are listed.                                                                                                        |
| A14 | The app uses static `replicas`, but it is a stateless web-facing workload. Consider an HPA (`minReplicas`/`maxReplicas`) for traffic-driven scaling instead of a hardcoded count.                                                   |

---

## Security & Exposure

| #   | Check                                                                                                                                                                                                         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A10 | The app is on `edge-gateway` (public), but it has no SecurityPolicy OIDC or equal auth. Make sure that this is intentional, or recommend a gate: `components/tinyauth` (standard) or `components/envoy-oidc`. |
| A11 | Secrets go in as environment variables, but the app supports secrets mounted as files. `kubectl describe pod` shows env vars. If the app supports it, recommend secretMount.                                  |

---

## Observability

| #   | Check                                                                                                                                                                                                                                                                                                                                                         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A18 | The app exposes a `/metrics` endpoint (read the image docs or the port list), but no ServiceMonitor is present, so nothing scrapes the metrics. This cluster has no kube-prometheus-stack. It runs separate VictoriaMetrics parts (`observability/victoria/*`), and the VM operator converts `ServiceMonitor` and `VMNodeScrape`. Recommend a ServiceMonitor. |

---

## Image Compatibility

| #   | Check                                                                                                                                                                                                             |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A19 | The image has `PUID`/`PGID` env vars (Linuxserver-style). The entrypoint starts as root to create its user. Skip H8/H9/H10/H22/H23/H24. Only `fsGroup` and `fsGroupChangePolicy` are safe in `defaultPodOptions`. |
| A20 | The image is based on Chrome or Chromium. Chrome writes to its profile directory at startup. Skip H23 (`readOnlyRootFilesystem`). The image crashes even when a `/tmp` emptyDir is present.                       |

---

## Architecture

| #   | Check                                                                                                                                                                                          |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A12 | The app has several logical components (for example app + database + worker) in one HelmRelease. Consider separate kustomizations for them, so that each reconciles and rolls back on its own. |
| A16 | The app uses a `Deployment` controller, but it mounts a PVC and needs a stable pod identity. If restart order matters, consider a `StatefulSet` (`type: statefulset` in app-template).         |

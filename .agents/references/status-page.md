# Status page — Frostlink hosts it for both clusters

`status.dcunha.io` is Frostlink's Gatus (`observability/gatus-sidecar`). It moved off Artemis so the page stays up when the house is down. It is also served at
`gatus-sidecar.frostlink.dev`; `status.frostlink.dev` was dropped. Live check count:
`curl -s 'https://status.dcunha.io/api/v1/endpoints/statuses?pageSize=500' | jq length`.

## How a request reaches it

`status.dcunha.io` is a grey Cloudflare CNAME to `edge.frostlink.dev`. **The record is owned by
Artemis** (`network/cloudflare-dns/app/dnsendpoint.yaml`), because Artemis's external-dns owns the
`dcunha.io` zone. Frostlink's Envoy (the front door, `networking.md` § The front door) terminates
TLS and `external-gateway` serves it with `dcunha-io-tls`, imported from 1Password by
`certificates/import`. The LAN gets the same Cloudflare answer — there is no internal record.

**Moving a hostname: check for stale records first.** The move was blocked by a Cloudflare CNAME
owned by a different external-dns owner and a UniFi static-DNS entry, both of which win over the
new record. `dig status.dcunha.io @1.1.1.1` and `@10.10.99.1` before and after.

## Where the checks come from

| Source                                 | What                                                                                                          | Alerts   |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------- |
| `app/resources/cluster-endpoints.yaml` | Hand-written: core (ping, home-link, status-page, headscale), the two agentgateway MCP checks, the heartbeats | Pushover |
| `gatus-sidecar` container              | Generated from Frostlink's own HTTPRoutes and Services                                                        | none     |
| `gatus-sidecar-artemis` container      | Generated from **Artemis's** HTTPRoutes and Services                                                          | none     |

Only hand-written checks page. A site-link outage therefore pages Home Link plus the two
MCP checks, not every generated Artemis check.

**The Artemis sidecar runs in remote mode.** `KUBERNETES_SERVICE_HOST=""` forces it off the
in-cluster config and onto `KUBECONFIG=/kube/config`, mounted from secret
`gatus-artemis-kubeconfig` (1Password `frostlink/gatus` → `ARTEMIS_KUBECONFIG`). That kubeconfig holds
the token of Artemis's `observability/gatus-remote-reader` ServiceAccount — read-only on services,
gateways and httproutes, a long-lived token that only changes when rotated by hand. It reaches the
Artemis API over the Headscale site link.

Things that each cost a failed attempt:

- **Gateway group names must be unique across both clusters.** Each sidecar names a gateway's
  checks after its group; two gateways both grouped `external` produced a duplicate key and
  crashed Gatus. Frostlink's `external-gateway` uses group `frostlink`.
- **The sidecars do not regenerate when only a Gateway annotation changes.** Restart the
  deployment after editing `gatus.home-operations.com/endpoint` on a Gateway.
- **Internal names resolve over the site link per endpoint.** Artemis's `internal-gateway`
  annotation sets `client.dns-resolver: tcp://10.10.99.1:53`, so every generated internal check asks
  UniFi directly. Do not set a resolver on Artemis's _external_ gateway to UniFi — internal answers
  for public names would make those checks lie.
- **`gatus.delayStartSeconds: "20"`.** Gatus reads its config once at start, and the remote sidecar
  needs ~7 s to write `artemis-sidecar.yaml`. With a shorter delay Gatus loaded a stale file. Gatus
  also ignores a file rewrite landing in the same second as its last load.

## Heartbeats

Three `external-endpoints` in `cluster-endpoints.yaml`, each expecting a POST every 5 min:

| Endpoint         | Sender                                                          | Token                                    |
| ---------------- | --------------------------------------------------------------- | ---------------------------------------- |
| `core_heartbeat` | Phare (external uptime service)                                 | `HEARTBEAT_TOKEN` (1P `gatus`)           |
| `core_artemis`   | Artemis Alertmanager `Watchdog` → `gatus-sidecar.frostlink.dev` | `HEARTBEAT_ARTEMIS_TOKEN` (1P `gatus`)   |
| `core_frostlink` | Frostlink Alertmanager `Watchdog` → `status.dcunha.io`          | `HEARTBEAT_FROSTLINK_TOKEN` (1P `gatus`) |

Phare also watches the page from outside, which covers the case Gatus cannot: Frostlink itself
being down.

## Metrics and badges

Artemis scrapes `https://status.dcunha.io/metrics` (`victoria/agent/vmstaticscrape-gatus.yaml`,
`job=gatus`, `instance=frostlink`), and its kromgo renders the `core_*` badges from that. If the
scrape stops, the badges keep showing the last value.

## Alert plumbing on this cluster

- `VMAlert.selectAllByDefault: true` evaluates every `VMRule`, including the ones vm-operator
  converts from chart-shipped `PrometheusRule`s (kopiur, towonel).
- kube-state-metrics runs with `honorLabels: true`. Without it the scrape's own target labels
  (`namespace=observability`, `pod=kube-state-metrics-*`) overwrite the `namespace`/`pod` labels on
  every `kube_*` metric, so alerts name the exporter instead of the broken workload —
  `KubePodCrashLooping` once pointed at kube-state-metrics while the crashlooper was
  `matrix/mautrix-whatsapp`.

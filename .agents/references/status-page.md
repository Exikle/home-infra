# Status page — Frostlink hosts it for both clusters

`status.dcunha.io` is Frostlink's Gatus (`observability/gatus-sidecar`). It moved off Artemis on
2026-10-03 so the page stays up when the house is down. It is also served at
`gatus-sidecar.frostlink.dev`; `status.frostlink.dev` was dropped. Live check count:
`curl -s 'https://status.dcunha.io/api/v1/endpoints/statuses?pageSize=500' | jq length`.

## How a request reaches it

`status.dcunha.io` is a proxied Cloudflare CNAME to Frostlink's tunnel. **The record is owned by
Artemis** (`network/cloudflare-tunnel/app/dnsendpoint.yaml`, target
`${FROSTLINK_TUNNEL_ID}.cfargotunnel.com`), because Artemis's external-dns owns the `dcunha.io`
zone. Frostlink's `cloudflare-tunnel` has an ingress rule for the name, and `external-gateway`
serves it with `dcunha-io-tls`, imported from 1Password by `certificates/import`. The LAN gets the
same Cloudflare answer — there is no internal record.

**Moving a hostname: check for stale records first.** The move was blocked by a Cloudflare CNAME
owned by a different external-dns owner and a UniFi static-DNS entry, both of which win over the
new record. `dig status.dcunha.io @1.1.1.1` and `@10.10.99.1` before and after.

## Where the checks come from

| Source                                 | What                                                                                                       | Alerts   |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------- | -------- |
| `app/resources/cluster-endpoints.yaml` | Hand-written: core (ping, Home Link, status page, Headscale), the three Litellm MCP checks, the heartbeats | Pushover |
| `gatus-sidecar` container              | Generated from Frostlink's own HTTPRoutes and Services                                                     | none     |
| `gatus-sidecar-artemis` container      | Generated from **Artemis's** HTTPRoutes and Services                                                       | none     |

Only hand-written checks page. A site-link outage therefore pages Home Link plus the three
Litellm checks, not every generated Artemis check.

**The Artemis sidecar runs in remote mode.** `KUBERNETES_SERVICE_HOST=""` forces it off the
in-cluster config and onto `KUBECONFIG=/kube/config`, mounted from secret
`gatus-artemis-kubeconfig` (1Password `frostlink/gatus-artemis-kubeconfig`). That kubeconfig holds
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

| Endpoint         | Sender                                                          | Token                                              |
| ---------------- | --------------------------------------------------------------- | -------------------------------------------------- |
| `core_heartbeat` | Phare (external uptime service)                                 | `HEARTBEAT_TOKEN` (1P `gatus`)                     |
| `core_artemis`   | Artemis Alertmanager `Watchdog` → `gatus-sidecar.frostlink.dev` | `HEARTBEAT_ARTEMIS_TOKEN` (1P `gatus-crosslink`)   |
| `core_frostlink` | Frostlink Alertmanager `Watchdog` → `status.dcunha.io`          | `HEARTBEAT_FROSTLINK_TOKEN` (1P `gatus-crosslink`) |

Phare also watches the page from outside, which covers the case Gatus cannot: Frostlink itself
being down.

## Metrics and badges

Artemis scrapes `https://status.dcunha.io/metrics` (`victoria/agent/vmstaticscrape-gatus.yaml`,
`job=gatus`, `instance=frostlink`), and its kromgo renders the `core_*` badges from that. If the
scrape stops, the badges keep showing the last value.

# Status page — Frostlink hosts it for both clusters

`status.dcunha.io` is Frostlink's Gatus (`observability/gatus-sidecar`). It moved off Artemis so the page stays up when the house is down. It is also served at
`status.frostlink.dev` and `gatus-sidecar.frostlink.dev`. Frostlink's external-dns makes the
`frostlink.dev` records from the HTTPRoute hostnames. Live check count:
`curl -s 'https://status.dcunha.io/api/v1/endpoints/statuses?pageSize=500' | jq length`.

## How a request reaches it

`status.dcunha.io` is a grey Cloudflare CNAME to `edge.frostlink.dev`. **The record is owned by
Artemis** (`network/cloudflare-dns/app/dnsendpoint.yaml`), because Artemis's external-dns owns the
`dcunha.io` zone. Frostlink's Envoy (the front door, `oci-networking.md` § The front door) terminates
TLS and `external-gateway` serves it with `dcunha-io-tls`, imported from 1Password by
`certificates/import`. The LAN gets the same Cloudflare answer — there is no internal record.

**Moving a hostname: check for stale records first.** The move was blocked by a Cloudflare CNAME
owned by a different external-dns owner and a UniFi static-DNS entry, both of which win over the
new record. `dig status.dcunha.io @1.1.1.1` and `@10.10.99.1` before and after.

## Where the checks come from

| Source                                           | What                                                                                   | Alerts                       |
| ------------------------------------------------ | -------------------------------------------------------------------------------------- | ---------------------------- |
| Frostlink `app/resources/cluster-endpoints.yaml` | Hand-written: core (ping, status-page, headscale), the heartbeats                      | Pushover                     |
| Frostlink `gatus-sidecar` container              | Generated from Frostlink's own HTTPRoutes and Services                                 | none                         |
| Artemis Gatus, pushed to Frostlink (`home.yaml`) | Generated from Artemis's HTTPRoutes and Services, plus the two agentgateway MCP checks | MCP checks page from Artemis |

The tailnet carries no status traffic (#3297). Frostlink cannot reach any home-only service, so
home runs its own checks and reports in.

### Home reports in

Artemis runs its own Gatus (`observability/gatus-sidecar` on Artemis) with gatus-sidecar in normal
in-cluster mode. It reads the same `gatus.home-operations.com` annotations as before, so a new app
gets a check with no extra step. The MCP checks are hand-written in Artemis's
`app/resources/cluster-endpoints.yaml`, and they page through Artemis's Pushover title `Gatus | Artemis`.

The checks for public sites (group `edge`) use the resolver `1.1.1.1`. They get the public answer,
leave the house and come back through Frostlink's front door, the same path as a visitor.
Internal checks use cluster DNS, which forwards `dcunha.io` to the UCG.

Every minute, the `push` container (`app/resources/push.sh` on Artemis) reads the newest result of
every check from the local Gatus API. It sends the whole list in one POST to
`https://status.dcunha.io/api/v1/home-push`, with the token `HOME_PUSH_TOKEN` (1Password
`frostlink/gatus`, read by both clusters).

On Frostlink, the `home-push` container (`app/resources/receiver.py`) answers that path through
Service `gatus-home-push`. It does three things:

1. It refuses any request without the token.
2. It writes `/config/home.yaml`: one `external-endpoint` for each check, with a 5 minute
   heartbeat. It writes the file only when the list of names changes.
3. It forwards each new result to the local Gatus external-endpoint API.

The receiver accepts names, groups and results only, never URLs. A leaked token can post false
results, but it cannot make Frostlink probe an address. Names must match `[A-Za-z0-9 ._-]`, so a
name cannot inject a `${VAR}` into the Gatus config.

If home stops pushing, `home.yaml` stays on the Frostlink PVC and every home check turns red. A
test on 2026-11-17 (Artemis Gatus scaled to 0) turned all 57 red in 9 minutes. Gatus checks a
heartbeat once for each interval, so the worst case is twice the interval. A 10 minute heartbeat
took 20 minutes.

Things that each cost a failed attempt:

- Gatus re-reads its config folder every 30 seconds when a file changes. A reload restarts all
  monitoring. The first push after a new app appears gets `404` from Gatus for that app. The
  receiver retries on the next push. Frostlink sets `skip-invalid-config-update: true`, so a bad
  `home.yaml` cannot crash Gatus at reload.
- Deleting a file from `/config` does not trigger a reload, because Gatus compares modification
  times. The old `artemis-sidecar.yaml` stayed loaded until the next write of `home.yaml`.
- Two files that define the same key make the config invalid. A check that moves between a
  regular endpoint and a pushed one needs the old file removed first.
- Gateway group names must be unique across both clusters. Two gateways both grouped `external`
  produced a duplicate key and crashed Gatus. Frostlink's `external-gateway` uses group `frostlink`.
- The sidecars do not regenerate when only a Gateway annotation changes. Restart the deployment
  after you edit `gatus.home-operations.com/endpoint` on a Gateway.
- Artemis's Gatus sets `ndots: 1`. Without it, every public name walks the search list and sends
  `<name>.observability.svc.cluster.local` lookups to `1.1.1.1`.

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

## Theme

The page uses Solarized (<https://ethanschoonover.com/solarized/>), the same palette as the Forgejo
theme. `ui.custom-css` in `resources/config.yaml` sets it. Gatus colours its UI from shadcn
variables (`--background`, `--primary` and the rest). Each variable holds an HSL triplet without
`hsl()`. `html:root` sets the light mode, and `html:root.dark` sets the dark mode.

The colour choices for text follow Forgejo (`ansible.md` § Themes are shipped by the role wins for the shared reasons):

- Links use `#1b6ea3` in light and `#54a0d3` in dark, not Solarized blue `#268bd2`.
- Body text is `base02` in light and `base1` in dark.

Gatus also has its own deviations:

- The status bars use the true Solarized green, red and yellow in both modes.
- The status text in light mode uses darker colours (`#687800`, `#da2825`, `#8f6c00`). The
  true colours measure under 4.5:1 on `base3`. In dark mode, only red changes (`#e56663`).
- The dark-mode text rules match `.dark [class*="text-green-"]`. Gatus sets dark text with
  classes such as `dark:text-green-400`, and a `.dark .text-green-400` selector does not match them.
- Secondary text in dark mode is `base0`. It measures 4.75:1 on the page, but only 3.7:1 on the
  `--muted` surface.

## Alert plumbing on Frostlink

- `VMAlert.selectAllByDefault: true` evaluates every `VMRule`, including the ones vm-operator
  converts from chart-shipped `PrometheusRule`s (kopiur, towonel).
- kube-state-metrics runs with `honorLabels: true`. Without it the scrape's own target labels
  (`namespace=observability`, `pod=kube-state-metrics-*`) overwrite the `namespace`/`pod` labels on
  every `kube_*` metric, so alerts name the exporter instead of the broken workload —
  `KubePodCrashLooping` once pointed at kube-state-metrics while the crashlooper was
  `matrix/mautrix-whatsapp`.

# Status page — Frostlink hosts it for both clusters

`status.dcunha.io` is the Gatus of Frostlink (`observability/gatus-sidecar`). It moved off Artemis,
so the page stays up when the house is down. Frostlink also serves it at `status.frostlink.dev` and
`gatus-sidecar.frostlink.dev`. The external-dns of Frostlink makes the `frostlink.dev` records from
the HTTPRoute hostnames. To get the live count of checks, run
`curl -s 'https://status.dcunha.io/api/v1/endpoints/statuses?pageSize=500' | jq length`.

## How a request reaches it

`status.dcunha.io` is a grey Cloudflare CNAME to `edge.frostlink.dev`. Artemis owns the record
(`network/cloudflare-dns/app/dnsendpoint.yaml`), because the external-dns of Artemis owns the
`dcunha.io` zone. The Envoy of Frostlink (the front door, `oci-networking.md` § The front door)
terminates TLS. `external-gateway` serves the name with `dcunha-io-tls`, which `certificates/import`
imports from 1Password. The LAN gets the same Cloudflare answer. There is no internal record.

If you move a hostname, look for stale records first. Two old records blocked this move: a
Cloudflare CNAME that a different external-dns owner held, and a UniFi static-DNS entry. Both win
over the new record. Run `dig status.dcunha.io @1.1.1.1` and `@10.10.99.1` before and after the
move.

## Where the checks come from

| Source                                           | What                                                                                   | Alerts                       |
| ------------------------------------------------ | -------------------------------------------------------------------------------------- | ---------------------------- |
| Frostlink `app/resources/cluster-endpoints.yaml` | Hand-written: core (ping, status-page, headscale), the heartbeats                      | Pushover                     |
| Frostlink `gatus-sidecar` container              | Generated from Frostlink's own HTTPRoutes and Services                                 | none                         |
| Artemis Gatus, pushed to Frostlink (`home.yaml`) | Generated from Artemis's HTTPRoutes and Services, plus the two agentgateway MCP checks | MCP checks page from Artemis |

The tailnet carries no status traffic (#3297). Frostlink cannot reach any service that is only at
home. So home runs its own checks and reports the results to Frostlink.

### Home reports in

Artemis runs its own Gatus (`observability/gatus-sidecar` on Artemis). gatus-sidecar runs there in
the normal in-cluster mode. It reads the same `gatus.home-operations.com` annotations as before, so
a new app gets a check with no extra step. The MCP checks are hand-written in
`app/resources/cluster-endpoints.yaml` on Artemis. They page through the Pushover title
`Gatus | Artemis` of Artemis.

The checks for public sites (group `edge`) use the resolver `1.1.1.1`. They get the public answer,
leave the house and come back through the front door of Frostlink. This is the same path that a
visitor takes. Internal checks use cluster DNS, which forwards `dcunha.io` to the UCG.

Every minute, the `push` container (`app/resources/push.sh` on Artemis) reads the newest result of
every check from the local Gatus API. It sends the whole list in one POST to
`https://status.dcunha.io/api/v1/home-push`, with the token `HOME_PUSH_TOKEN`. The token is in the
1Password item `frostlink/gatus`, and both clusters read it.

On Frostlink, the `home-push` container (`app/resources/receiver.py`) answers that path through
Service `gatus-home-push`. It does three things:

1. It refuses any request without the token.
2. It writes `/config/home.yaml`: one `external-endpoint` for each check, with a 5 minute
   heartbeat. It writes the file only when the list of names changes.
3. It forwards each new result to the local Gatus external-endpoint API.

The receiver accepts names, groups and results only, never URLs. A leaked token can post false
results, but it cannot make Frostlink probe an address. Names must match `[A-Za-z0-9 ._-]`, so a
name cannot inject a `${VAR}` into the Gatus configuration.

If home stops pushing, `home.yaml` stays on the Frostlink PVC and every home check turns red. A
test on 2026-11-17 (Artemis Gatus scaled to 0) turned all 57 red in 9 minutes. Gatus checks a
heartbeat once for each interval, so the worst case is twice the interval. A 10 minute heartbeat
took 20 minutes.

Each of these facts cost a failed attempt:

- Gatus reads its configuration folder again every 30 seconds when a file changes. A reload
  restarts all monitoring. The first push after a new app appears gets `404` from Gatus for that
  app. The receiver tries again on the next push. Frostlink sets `skip-invalid-config-update: true`,
  so a bad `home.yaml` cannot crash Gatus at reload.
- Gatus does not reload when you delete a file from `/config`, because Gatus compares modification
  times. The old `artemis-sidecar.yaml` stayed loaded until the next write of `home.yaml`.
- Two files that define the same key make the configuration invalid. A check can move between a
  regular endpoint and a pushed one. Before it moves, remove the old file.
- Gateway group names must be unique across both clusters. Two gateways with the group `external`
  produced a duplicate key and crashed Gatus. The `external-gateway` of Frostlink uses group
  `frostlink`.
- The sidecars do not make the checks again when only a Gateway annotation changes. If you edit
  `gatus.home-operations.com/endpoint` on a Gateway, restart the deployment.
- The Gatus of Artemis sets `ndots: 1`. Without it, every public name walks the search list and
  sends `<name>.observability.svc.cluster.local` lookups to `1.1.1.1`.

## Heartbeats

`cluster-endpoints.yaml` holds three `external-endpoints`. Each one expects a POST every 5 minutes:

| Endpoint         | Sender                                                          | Token                                    |
| ---------------- | --------------------------------------------------------------- | ---------------------------------------- |
| `core_heartbeat` | Phare (external uptime service)                                 | `HEARTBEAT_TOKEN` (1P `gatus`)           |
| `core_artemis`   | Artemis Alertmanager `Watchdog` → `gatus-sidecar.frostlink.dev` | `HEARTBEAT_ARTEMIS_TOKEN` (1P `gatus`)   |
| `core_frostlink` | Frostlink Alertmanager `Watchdog` → `status.dcunha.io`          | `HEARTBEAT_FROSTLINK_TOKEN` (1P `gatus`) |

Phare also watches the page from outside. This covers the one case that Gatus cannot see: Frostlink
itself is down.

## Metrics and badges

Artemis scrapes `https://status.dcunha.io/metrics` (`victoria/agent/vmstaticscrape-gatus.yaml`,
`job=gatus`, `instance=frostlink`). The kromgo of Artemis renders the `core_*` badges from that
data. If the scrape stops, the badges keep the last value.

## Theme

The page uses Solarized (<https://ethanschoonover.com/solarized/>), the same palette as the Forgejo
theme. `ui.custom-css` in `resources/config.yaml` sets it. Gatus takes the colours of its UI from
shadcn variables (`--background`, `--primary` and the rest). Each variable holds an HSL triplet
without `hsl()`. `html:root` sets the light mode, and `html:root.dark` sets the dark mode.

The colour choices for text follow Forgejo (`ansible.md` § Themes are shipped by the role wins for
the shared reasons):

- Links use `#1b6ea3` in light and `#54a0d3` in dark, not Solarized blue `#268bd2`.
- Body text is `base02` in light and `base1` in dark.

Gatus also has its own deviations:

- The "up" colour is the green `#4fa34a`, not Solarized green. The owner rejected the olive
  `#859900`. The owner chose this green over Solarized cyan `#2aa198` and a brighter `#9ab800`.
- The status bars use `#4fa34a` and the true Solarized red and yellow in both modes.
- The status text in light mode uses darker colours (`#3d7e39`, `#da2825`, `#8f6c00`). The bar
  colours measure under 4.5:1 on `base3`. In dark mode, only red changes (`#e56663`).
- The dark-mode text rules match `.dark [class*="text-green-"]`. Gatus sets dark text with
  classes such as `dark:text-green-400`, and a `.dark .text-green-400` selector does not match them.
- Secondary text in dark mode is `base0`. It measures 4.75:1 on the page, but only 3.7:1 on the
  `--muted` surface.

## Alert plumbing on Frostlink

Both facts that were here apply to both clusters. They are now in `observability.md` § Alert
plumbing (both clusters).

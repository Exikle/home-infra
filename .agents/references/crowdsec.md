# CrowdSec — the front door's only CrowdSec

CrowdSec on frostlink checks every public request that reaches the Envoy of frostlink, for both
domains. This is the only CrowdSec. Artemis runs none (`towonel-agent.md`). Home boxes sit behind
the towonel backhaul (`towonel.md`), so their traffic is checked here before it leaves frostlink.
LAN traffic at home never goes through it.

It does three jobs:

- IP bans. The WASM filter syncs the LAPI decisions every 10 s and blocks those IPs. Most
  decisions come from the community blocklist (CAPI). No log agent reads the Envoy logs yet. The
  only local bans come from AppSec scenarios (see § Check it after a change).
- Bot challenge. AppSec makes a browser solve a proof-of-work check before it reaches a site.
  Clients without JavaScript (curl, apps, federation) also get the challenge page, unless a rule
  exempts them. CrowdSec calls this bot detection, and it marks the feature alpha. Before a
  CrowdSec bump, read the release notes for the new tag. To see the running tag, run
  `grep tag: kube/clusters/frostlink/apps/security/crowdsec/app/helmrelease.yaml`.
- Scrape block. One in-band rule, `frostlink/forgejo-anon-label-scrape`, blocks Forgejo issue,
  pull and milestone lists that filter on two or more labels. It lives in `appsec.rules` in
  `app/helmrelease.yaml`, and the `frostlink/appsec-bot-challenge` config loads it.

## Parts

| Piece             | Where                                                  | Job                                                                 |
| ----------------- | ------------------------------------------------------ | ------------------------------------------------------------------- |
| LAPI and AppSec   | `security/crowdsec`, from `apps/security/crowdsec/app` | LAPI holds the decisions and the bouncer key. AppSec scores clients |
| Exemption overlay | `appsec.configs` in `app/helmrelease.yaml`             | The hosts, headers and paths that are never challenged              |
| WASM filter       | `components/envoy/crowdsec/envoyextensionpolicy.yaml`  | Runs on the `https` listener of `external-gateway`, every route     |
| Clusters and key  | `components/envoy/crowdsec/kustomization.yaml`         | Patches `EnvoyProxy/envoy` so Envoy can reach LAPI and AppSec       |
| Key               | 1Password item `crowdsec`, field `BOUNCER_KEY_ENVOY`   | `ExternalSecret/crowdsec-wasm` in `network`, from the component     |

The filter is `aarnaud/crowdsec-wasm-bouncer`. `envoy-gateway/app/kustomization.yaml` pulls in the
component. The filter does not cover two listeners. The `http` listener only sends redirects. The
`headscale` TLS-passthrough listener is never decrypted.

## What is never challenged

The overlay holds our exemptions. Each rule carries a label in `ExemptFromChallenge("<label>")`.
To list every rule and its hosts, run
`grep -n ExemptFromChallenge kube/clusters/frostlink/apps/security/crowdsec/app/helmrelease.yaml`.
The vendored `crowdsecurity/appsec-bot-challenge-exclude-*` configs in `appsec_configs` add more
exemptions (for example search engines, feeds and monitoring). Read both there, not here.

Our rules fall into three kinds. Each kind exists because its clients cannot solve the challenge:

- Any host: requests that carry a machine marker. These are ActivityPub content types, signed
  requests and the `Gatus/` user agent. Federation and the status checks send them.
- Whole hosts: hosts whose clients are all machines, such as the towonel hub, Matrix and the
  Jellyfin-compatible API of silo. `id.dcunha.io` is also exempt as a whole host, because apps
  call the OIDC endpoints of Pocket-ID directly.
- Machine paths on browser hosts: the protocol paths of a site that a person also opens in a
  browser. Examples are the registry and Git paths, e-reader sync on books, the API of the
  phone-app services, the status API and `/.well-known/` on both apex domains.

The hub must stay exempt. The towonel agents refresh their credentials through it. If the hub is
challenged or blocked, every home backhaul fails when those credentials expire.

## Rules that bite

- List the AppSec configs by name. The wildcard `crowdsecurity/appsec-bot-*` also loads
  `appsec-bot-challenge-warn-experimental`. `appsec-default` needs out-of-band rules that are not
  installed. Either one stops the AppSec pod with `no appsec-rules found`.
- The init container of the AppSec pod has a 50Mi memory limit in the chart. It hits the limit
  and spins forever. A `postRenderers` patch in `app/helmrelease.yaml` raises the limit to 256Mi.
- The `sha256` field of the policy is the checksum of the WASM module, not of the image. Apply
  with a wrong value. Then read the right one from `.status.ancestors[].conditions[]`.
- `failOpen` is on, for both the filter and AppSec. If CrowdSec is down, the sites stay up without
  checks. If you turn it off, every public site goes down with CrowdSec, the hub included.
- The filter ignores `captcha` decisions. It enforces only `ban` (IP and range), so a captcha
  profile does nothing here.
- If a route has its own `EnvoyExtensionPolicy`, that policy overrides the gateway-wide one for
  that route.

## Check it after a change

Keep a test run to a few requests. On 2026-11-14, about 70 curl requests from home tripped the
`crowdsecurity/appsec-bot-challenge-too-many-requests` scenario. CrowdSec banned the home public
IP for about 3 hours. To lift such a ban, run `cscli decisions delete --ip <ip>` on the LAPI.

1. Request `https://social.frostlink.dev/` with a browser user agent. You must get the page
   titled `CrowdSec Challenge`.
2. Request each machine path. None of them must get the challenge:
    - Webfinger and `/nodeinfo/2.0` on social.
    - A fetch of a user with `Accept: application/activity+json`.
    - `https://registry.frostlink.dev/v2/` (401 JSON).
    - `https://matrix.frostlink.dev/_matrix/client/versions`.
    - `https://hub.frostlink.dev/v1/readyz`.
3. Run `cscli bouncers list` on the LAPI. It shows when the `ENVOY` bouncer last pulled.

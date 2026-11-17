# CrowdSec — the front door's only CrowdSec

CrowdSec on frostlink checks every public request that reaches frostlink's Envoy, for both domains.
Under the Shape 1 front door (Artemis issue #3082), this is the only CrowdSec. Artemis runs none.
Home boxes sit behind the towonel backhaul (`towonel.md`), so their traffic is checked here
before it leaves frostlink. LAN traffic at home never passes through it.

It does two jobs:

- **IP bans.** The WASM filter syncs the LAPI decisions every 10 s and blocks those IPs. Today the
  decisions are the community blocklist (CAPI). No log agent runs yet, so frostlink makes no
  bans of its own.
- **Bot challenge.** AppSec makes a browser solve a proof-of-work check before it reaches a site.
  Clients without JavaScript (curl, apps, federation) get the challenge page too, unless a rule
  exempts them. CrowdSec calls this bot detection, and it is alpha in CrowdSec 1.8.

## Parts

| Piece             | Where                                                  | Job                                                                 |
| ----------------- | ------------------------------------------------------ | ------------------------------------------------------------------- |
| LAPI and AppSec   | `security/crowdsec`, from `apps/security/crowdsec/app` | LAPI holds the decisions and the bouncer key. AppSec scores clients |
| Exemption overlay | `appsec.configs` in `app/helmrelease.yaml`             | The hosts, headers and paths that are never challenged              |
| WASM filter       | `components/envoy/crowdsec/envoyextensionpolicy.yaml`  | Runs on the `https` listener of `external-gateway`, every route     |
| Clusters and key  | `components/envoy/crowdsec/kustomization.yaml`         | Patches `EnvoyProxy/envoy` so Envoy can reach LAPI and AppSec       |
| Key               | 1Password item `crowdsec`, field `BOUNCER_KEY_ENVOY`   | `ExternalSecret/crowdsec-wasm` in `network`, from the component     |

The filter is `aarnaud/crowdsec-wasm-bouncer`. `envoy-gateway/app/kustomization.yaml` pulls in the
component. The `http` listener (redirects only) and the `headscale` TLS-passthrough listener are
not covered: one only redirects, and the other is never decrypted.

## What is never challenged

The overlay lists every exemption, one rule per kind of client. Read it there, not here. The kinds:

- **Any host:** ActivityPub (`activity+json` or `ld+json` in `Accept` or `Content-Type`), signed
  requests (`Signature: keyId=`), and the `Gatus/` user agent.
- **Whole hosts with machine clients only:** the towonel hub, Matrix, atuin, flux-webhook,
  kromgo (both domains), Jellyfin and xBrowserSync.
- **Machine paths on browser hosts:** registry `/v2/` and `/ap/`; git smart-HTTP, LFS, API and
  Actions; OIDC on pocket-id; OPDS, KOReader, `/api/` and the `POST /login` of the Audiobookshelf-style API on books; the `/api/` of the phone-app services;
  GoToSocial's service routes; `/.well-known/` on both apex domains.

**The hub must stay exempt.** The towonel agents refresh their credentials through it. If it is
challenged or blocked, every home backhaul fails once those credentials expire.

## Rules that bite

- List the AppSec configs by name. The wildcard `crowdsecurity/appsec-bot-*` also loads
  `appsec-bot-challenge-warn-experimental`, and `appsec-default` needs out-of-band rules that are
  not installed. Either one stops the AppSec pod with `no appsec-rules found`.
- The init container of the AppSec pod has a 50Mi memory limit in the chart. It hits the limit
  and spins forever. A `postRenderers` patch raises the limit.
- The `sha256` field of the policy is the checksum of the WASM module, not of the image. Apply
  with a wrong value, then read the right one from `.status.ancestors[].conditions[]`.
- `failOpen` is on, for both the filter and AppSec. If CrowdSec is down, sites stay up unchecked.
  Turning it off would take every public site down with CrowdSec, the hub included.
- The filter ignores `captcha` decisions. Only `ban` (IP and range) is enforced, so a captcha
  profile does nothing here.
- A route with its own `EnvoyExtensionPolicy` overrides the gateway-wide one for that route.

## Check it after a change

A browser user agent must get the page titled `CrowdSec Challenge` from
`https://social.frostlink.dev/`. Machine paths must not: webfinger and `/nodeinfo/2.0` on social,
an `Accept: application/activity+json` fetch of a user, `https://registry.frostlink.dev/v2/`
(401 JSON), `https://matrix.frostlink.dev/_matrix/client/versions`, and
`https://hub.frostlink.dev/v1/readyz`. `cscli bouncers list` on the LAPI shows when the `ENVOY`
bouncer last pulled.

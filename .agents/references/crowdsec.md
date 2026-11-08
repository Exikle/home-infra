# CrowdSec — Bot Challenge for GoToSocial

CrowdSec protects `social.frostlink.dev` with a bot challenge. A browser must solve a
proof-of-work check before it reaches GoToSocial. Plain `curl` and other clients without
JavaScript get the challenge page too, unless a rule exempts them. CrowdSec calls this feature bot
detection, and it is alpha in CrowdSec 1.8. This cluster has no log agents and no IP bans. The
challenge is the only job.

The Artemis cluster runs the same design. Its reference is `crowdsec.md` in the Artemis-Cluster
repo, which also has the debugging notes.

## Parts

| Piece             | Where                                                  | Job                                                                   |
| ----------------- | ------------------------------------------------------ | --------------------------------------------------------------------- |
| LAPI and AppSec   | `security/crowdsec`, from `apps/security/crowdsec/app` | LAPI holds the bouncer key. AppSec scores clients and serves the page |
| Exemption overlay | `appsec.configs` in `app/helmrelease.yaml`             | Lists the hosts, headers and paths that are never challenged          |
| WASM filter       | `EnvoyExtensionPolicy` next to the route               | Asks AppSec about each request and returns the challenge page         |
| Clusters and key  | `EnvoyProxy/envoy` in `envoy-gateway/app/envoy.yaml`   | Lets Envoy reach AppSec, and passes the key to the filter             |
| Key               | 1Password item `crowdsec`, field `BOUNCER_KEY_ENVOY`   | `ExternalSecret/crowdsec-wasm` in `network` copies it                 |

The filter is `aarnaud/crowdsec-wasm-bouncer`. It runs only on routes that have an
`EnvoyExtensionPolicy`.

## What is never challenged

ActivityPub traffic must pass, or federation breaks. The overlay exempts a request when:

- The `Accept` or `Content-Type` header contains `activity+json` or `ld+json`.
- The `Signature` header contains `keyId=`.
- The path is one of the service routes of GoToSocial: `/api/`, `/oauth/`, `/auth/`,
  `/fileserver/`, `/nodeinfo/`, `/users/`, `/emoji/`, `/assets/`, `/settings`, `/signup`,
  `/authorize_interaction`, `/inbox`, `/custom_css` and `/.well-known/`.
- The user agent starts with `Gatus/`.

## Rules that bite

- List the AppSec configs by name. The wildcard `crowdsecurity/appsec-bot-*` also loads
  `appsec-bot-challenge-warn-experimental`, and `appsec-default` needs out-of-band rules that are
  not installed. Either one stops the AppSec pod with `no appsec-rules found`.
- The init container of the AppSec pod has a 50Mi memory limit in the chart. It hits the limit
  and spins forever. A `postRenderers` patch raises the limit.
- The `sha256` field of the policy is the checksum of the WASM module, not of the image. Apply
  with a wrong value, then read the right one from `.status.ancestors[].conditions[]`.
- `failOpen` is on. If AppSec is down, nothing is challenged.

## Check it after a change

A browser user agent and plain `curl` must get the page titled `CrowdSec Challenge` from
`https://social.frostlink.dev/`. These must not:

- `/.well-known/webfinger?resource=acct:<user>@social.frostlink.dev` must return JSON.
- `/nodeinfo/2.0` must return JSON.
- A request with `Accept: application/activity+json` to `/users/<user>` must return JSON.

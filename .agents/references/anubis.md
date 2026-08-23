# Anubis — Proof-of-Work Scraper Deterrence

Anubis sits in front of an app as a reverse proxy and makes unrecognised clients solve a
proof-of-work challenge before reaching the backend. It exists to slow AI crawlers that ignore
`robots.txt`. Deployed on Frostlink in front of `gotosocial` only.

Upstream: <https://github.com/TecharoHQ/anubis>

---

## Component Shape

The component is kept near-identical to Artemis's. `diff -ru` on 2026-08-22 shows exactly four
deltas — 1Password item (`anubis` vs `anubis-artemis`), skip-annotation domain
(`*.frostlink.dev` vs `*.dcunha.io`), `$schema` URLs (`json.schemastore.org` vs
`k8s-schemas.home-operations.com`), and `USE_REMOTE_ADDRESS`, which only Artemis sets and which
must **not** be synced here (§ Client IP). Fix any other bug in both.

`kubernetes/components/anubis/` is a flat kustomize Component with two jobs:

```text
components/anubis/
├── kustomization.yaml     # Component — pulls in ./base, applies the route patch
└── base/
    ├── kustomization.yaml
    ├── externalsecret.yaml
    ├── helmrelease.yaml
    └── ocirepository.yaml
```

1. **Add the workload.** `base/` holds the OCIRepository, HelmRelease and ExternalSecret for
   `${APP}-anubis`. They are built inline into the consuming app's Kustomization, so they land in
   that app's `targetNamespace` with no extra wiring.
2. **Re-point the route.** A JSON patch swaps `route.app.rules[0].backendRefs` in the consuming
   app's HelmRelease to `${APP}-anubis:8080`.

### Why the skip annotation exists

The route patch targets *all* HelmReleases in the build — including Anubis's own, which would
make it proxy to itself. It cannot exclude Anubis by name, because `${APP}` is substituted by Flux
at `postBuild` time, *after* kustomize has already run, so a `name: ${APP}-anubis` target matches
nothing during the build.

So the component's own HelmRelease carries
`anubis.frostlink.dev/skip-route-patch: "true"`, and the patch selects on
`annotationSelector: "!anubis.frostlink.dev/skip-route-patch"`. That is the only thing keeping the
patch off Anubis itself — **do not remove that annotation.** The same key is the escape hatch for
any other HelmRelease that should be exempt.

(Upstream examples solve this by hiding Anubis behind a nested Flux Kustomization instead. The
annotation achieves the same thing without the extra directory level and extra reconciliation.)

The patch replaces only `backendRefs`, not the whole `rules` array. Replacing `rules` wholesale
(as some upstream examples do) silently drops sibling `filters` — it would have destroyed
gotosocial's CORS filter, which Phanpy depends on.

### Consuming it

```yaml
components:
  - ../../../../components/anubis
postBuild:
  substitute:
    ANUBIS_TARGET: http://gotosocial.fediverse.svc.cluster.local:8080
    APP: gotosocial
```

Only `APP` and `ANUBIS_TARGET` are needed. The app's ks must already have
`onepassword-connect` in `dependsOn` for the ExternalSecret to resolve.

`ANUBIS_TARGET` must be the backend's real cluster address — Anubis proxies to it. The app's own
Service keeps its original name, so the target does not change when the route is re-pointed.

### Policy lives with the app, not the component

The component mounts a ConfigMap named `${APP}-anubis-policy` that it does **not** create. Each
consuming app ships its own `anubis-policy.yaml`. Policies are highly app-specific — what is safe
to challenge on a fediverse server is not what is safe on a git forge — so keeping them out of the
component is what lets the component stay identical across both clusters.

---

## The Fediverse Problem

Anubis in front of an ActivityPub server is a sharp-edged combination. Upstream issue
[#31](https://github.com/TecharoHQ/anubis/issues/31) ("See if Anubis breaks activitypub
federation") is still **open** — it has never been formally resolved.

The `gotosocial-anubis-policy` ConfigMap is built around one central rule: **federation is
identified by content type, not by path.** Any request whose `Accept` or `Content-Type` mentions
`activity+json` or `ld+json` is allowed through unchallenged, as is anything carrying an HTTP
Signature. Server-to-server traffic therefore cannot be broken by a path allow-list going stale.
Browser traffic sends `Accept: text/html` and still gets challenged.

On top of that, these paths are allowed because clients and tooling break without them:

| Path                      | Why                                            |
| ------------------------- | ---------------------------------------------- |
| `/api/`, `/oauth/`, `/auth/` | Mastodon client API — Phanpy, all mobile apps |
| `/fileserver/`            | GtS media; challenged media = broken images    |
| `/users/`, `/emoji/`      | ActivityPub actors, collections, custom emoji  |
| `/nodeinfo/`              | Instance discovery                             |
| `/authorize_interaction`  | Remote follow flow                             |
| `/settings`, `/assets/`   | Settings panel and static assets               |

`.well-known` is **not** in the policy because it never reaches Anubis at all — gotosocial's
`route.wellknown` is a separate HTTPRoute that the component's patch does not touch, so WebFinger
and host-meta go straight to the backend. Leave that route alone.

### Known breakage

- **Phanpy is not protected, deliberately.** Anubis issue
  [#976](https://github.com/TecharoHQ/anubis/issues/976) is an open CORS bug specific to Phanpy.
  It is also why the `/api/` allow above is mandatory — Phanpy talks to `social.frostlink.dev`.
- **OpenGraph previews** break without `OG_PASSTHROUGH` (issue
  [#168](https://github.com/TecharoHQ/anubis/issues/168)). It is set in the component; do not
  remove it. Note the tradeoff: issue
  [#435](https://github.com/TecharoHQ/anubis/issues/435) reports bots using OG to bypass Anubis.
- **apoci is not protected.** An OCI registry needs `^/v2/.*` allowed or image pulls break, and a
  registry has little scrapeable value. Adding it means parameterising the policy first.

### How effective is this, really?

Worth being honest about. GoToSocial shipped its own PoW deterrence (`nollamas`) and then
**removed it in September 2025**
([#4433](https://codeberg.org/superseriousbusiness/gotosocial/issues/4433)); the maintainer cited
[pow-buster](https://github.com/eternal-flame-AD/pow-buster), a SIMD solver with explicit Anubis
coverage, and wrote that "both our hacky implementation especially, and more popular ones (like
anubis) aren't looking too great on the deterrent front."

Anubis raises the cost for low-effort crawlers. It does not stop a determined one. Treat it as a
rate-limiting speed bump, not a wall.

---

## Component Interactions — all three bit during the first deploy

Adding a second workload to an app's Kustomization means every *other* component's patch sees it
too. Three separate things broke before this worked:

**1. `postgres/cert` injected a Postgres client cert into Anubis.** Its patch in
`components/postgres/base/patch/` targeted all HelmReleases and mounts
`postgres-{{ .Release.Name }}-cert`, so Anubis waited forever on a nonexistent
`postgres-gotosocial-anubis-cert` and sat in `Init:0/1`. Fixed by giving that patch
`annotationSelector: "!postgres.frostlink.dev/skip-cert-patch"` and annotating Anubis's
HelmRelease. Any future sidecar added via a component needs the same annotation.

**2. fingerjoin started fanning out to Anubis.** fingerjoin discovers WebFinger backends from
HTTPRoutes annotated `fingerjoin.naktis.eu/webfinger: "true"` and resolves their `backendRefs` to
a Service. Because the route patch rewrote `route.app`'s backend, fingerjoin resolved
`gotosocial-anubis` and `frostlink.dev/.well-known/webfinger` started returning 502. Fixed by
moving the annotation to `route.wellknown`, which the patch does not touch and which still points
at the GoToSocial Service. **Internal service-to-service traffic must bypass Anubis** — the
general lesson, not just for fingerjoin.

**3. Gatus was getting challenged.** The `allow-gatus-monitoring` rule
(`userAgent.startsWith("Gatus/")`) exists because otherwise the health check measures the
challenge page rather than GoToSocial. Worse than a false alarm: the interstitial returns HTTP
200, so a `[STATUS] == 200` check goes *green* while the app behind it is unverified. Note this
allow is user-agent based and therefore trivially spoofable — it is a deliberate trade of a
little bypass surface for meaningful monitoring.

---

## Client IP: Anubis needs `X-Real-Ip`

Anubis reads the client IP from the `X-Real-Ip` header and returns **HTTP 500
`[misconfiguration] X-Real-Ip header is not set`** if it cannot resolve one. It will derive the
header from `X-Forwarded-For`, but `xff.Parse` returns the first **non-private** address, so an
XFF chain containing only RFC1918 addresses yields nothing.

`XFF_STRIP_PRIVATE=false` does *not* help, and the reason matters if you are tempted to try it:
`XForwardedForUpdate` runs with `Flatten: true`, keeping only the **last** surviving entry of
`[client..., remoteAddr]`. Stop stripping private addresses and that last entry becomes Envoy's
own pod IP — so *every* client, external included, collapses onto one address. Strictly worse
than doing nothing.

**Frostlink is unaffected.** All external traffic arrives through the Cloudflare tunnel with a
public client IP, so `X-Real-Ip` is always populated and Frostlink keeps real per-client
identity. A purely internal route in front of Anubis would hit this.

**Artemis solved it differently, and the divergence is deliberate.** `git.dcunha.io` also
resolves to Artemis's `internal-gateway`, so LAN clients arrive with an all-private XFF chain and
500 on every allowed route. Artemis therefore sets `USE_REMOTE_ADDRESS: "true"` — Anubis takes the
TCP peer address, which is always present, at the cost of attributing every client to the Envoy
pod IP. **Do not copy that env var here**: it would throw away the real client IPs Frostlink does
get, for no benefit. Artemis's copy of this doc carries the full trade-off.

---

## Operational Notes

- **Store is in-memory.** No `store` block is configured, so challenge state is lost on restart
  and users re-solve once. This is deliberate: it avoids a dependency on the `database` Dragonfly,
  which currently has no other consumer on Frostlink and whose operator-owned NetworkPolicy
  behaviour is untested for this path. Add a `store.backend: valkey` block pointing at
  `redis://dragonfly.database.svc.cluster.local:6379/<db>` if challenge persistence is wanted.
- **Difficulty is set per-rule in the policy**, not via the `DIFFICULTY` env var. The env var
  route is a trap: `postBuild` substitution yields a bare integer, and container env values must
  be strings.
- **Key material** comes from the 1Password item `anubis`, field
  `ED25519_PRIVATE_KEY_HEX`. Rotating it invalidates every outstanding challenge cookie — which is
  harmless, users just re-solve.
- **Cookie names are derived from cookie settings** since Anubis v1.27.0. Changing any cookie
  option changes the cookie name by design, to avoid infinite challenge loops.
- **Metrics** are exposed on port 9090 and scraped via the `serviceMonitor` in the component.
  A rising challenge rate with a flat pass rate is the signal that a crawler is hammering.

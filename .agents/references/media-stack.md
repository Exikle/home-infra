# Media Stack — home-infra

The service ports were checked again against the live cluster on 2026-10-13. App lists go stale.
For the current set of apps, run `ls kube/clusters/artemis/apps/media/`. Do not trust the lists
in this file for that.

## Architecture

These apps live in `kube/clusters/artemis/apps/media/`.

### Acquisition

| App           | Image                                              | Role                                                                                            |
| ------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `sonarr`      | `ghcr.io/home-operations/sonarr`                   | TV (single instance, native `id.dcunha.io` OIDC, one user, see `identity-stack.md`)             |
| `radarr`      | `ghcr.io/home-operations/radarr`                   | Movies (native `id.dcunha.io` OIDC, one user, see `identity-stack.md`)                          |
| `prowlarr`    | `ghcr.io/home-operations/prowlarr`                 | Central indexer manager → syncs to Sonarr and Radarr (autobrr uses IRC announces, not Prowlarr) |
| `sabnzbd`     | `ghcr.io/home-operations/sabnzbd`                  | Usenet downloads                                                                                |
| `qbittorrent` | `ghcr.io/home-operations/qbittorrent-libtorrentv1` | Torrents. Single container, no VPN sidecar                                                      |
| `qui`         | `ghcr.io/autobrr/qui`                              | qBittorrent web UI + cross-seed automation. Upstream autobrr, not a fork                        |
| `autobrr`     | `ghcr.io/autobrr/autobrr`                          | IRC announcers for private trackers (`id.dcunha.io` OIDC)                                       |
| `bazarr`      | `ghcr.io/home-operations/bazarr`                   | Subtitles (behind the `envoy-oidc` component, own auth off, see `identity-stack.md`)            |
| `recyclarr`   | `ghcr.io/recyclarr/recyclarr`                      | Quality profile sync (CronJob, so no Service and no route)                                      |
| `trawl`       | `ghcr.io/germondai/trawl`                          | Camoufox/Firefox-based challenge solver, `:8191`. Dragonfly index 5 cache                       |

immich also lives in `media`. It moved from `default`. It has three Kustomizations
(`immich-app`, `immich-microservices`, `immich-machine-learning`). It has no `database/`
component, because it moved onto the shared CNPG cluster on 2026-09-01. immich is a photo
library and not part of the Arr chain. For that reason, it is not in the tables above.

### Playback and requests

| App     | Image                             | Role                                                                                                                       |
| ------- | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `silo`  | `ghcr.io/silo-server/silo-server` | Media server: `silo.dcunha.io` (native) + `jellyfin.dcunha.io` / `silo-jf.dcunha.io` (Jellyfin-compatible API). See § Silo |
| `seerr` | `ghcr.io/seerr-team/seerr`        | Requests: `seerr.dcunha.io` and `requests.dcunha.io`                                                                       |

### Books, comics, documents

| App              | Image                                 | Role                                                                                                                             |
| ---------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `bookboss`       | `ghcr.io/szinn/bookboss`              | Ebook library at `books.dcunha.io`, shared Postgres, OIDC                                                                        |
| `shelfmark`      | `ghcr.io/calibrain/shelfmark`         | Book search/ingest at `booksearch.dcunha.io`, `:8084`, OIDC, talks to Prowlarr on `:80`                                          |
| `rensaio`        | `docker.io/maxpiva/rensaio`           | Manga downloader, `:9833`, PUID 99 / PGID 100 (not the usual 1000), library at `downloads/kaizoku`                               |
| `audiobookshelf` | `ghcr.io/advplyr/audiobookshelf`      | Audiobook server at `audiobooks.dcunha.io`, `:13378`, with an `abs-tract` helper on `:5555`                                      |
| `jelu`           | `git.dcunha.io/exikle/jelugo`         | Book tracker (JeluGo) at `jelu.dcunha.io`, `:11111`, public on `edge-gateway` behind the bot challenge                           |
| `komf`           | `git.dcunha.io/exikle/komfgo`         | Metadata for Komga (KomfGo, our Go port of komf, stateless, matches live in Komga links). Komga itself lives in `default`        |
| `paperless`      | `ghcr.io/paperless-ngx/paperless-ngx` | Document management: shared Postgres + Dragonfly index 1, plus `paperless-tika` and `paperless-gotenberg` sidecar kustomizations |

### Chat

| App         | Image                         | Role                            |
| ----------- | ----------------------------- | ------------------------------- |
| `thelounge` | `ghcr.io/thelounge/thelounge` | Self-hosted IRC client, `:9000` |

## Scale-to-zero — read this before diagnosing "X is down"

Several media apps carry `components/zeroscaler`. This component is an HPA with
`minReplicas: 0`. It scales the Deployment down and back up on an external `probe_success`
metric. The set of apps that carry it changes, so this file does not list them. Use these
commands:

```bash
grep -rln 'components/zeroscaler' kube/clusters/artemis/apps/   # the tree
kubectl get hpa -A                                   # what is actually live
```

These are the facts that catch people out:

- A zeroscaled app can correctly be at zero replicas. "No pods for sonarr" is not always an
  outage. Read the HPA before you escalate. But do not think that zero is the normal state.
  Every zeroscaled app normally sits at 1 replica. Read the live HPA, and do not assume either
  direction.
- `kubectl rollout restart` does nothing on a Deployment at zero replicas. To force a restart,
  first wake the app (open its hostname), and then restart it. You can also delete the running
  pod.
- The component is not only in `media`. `default/komga` carries it too, so a zeroscaler failure
  across the cluster also stops Komga. For that reason, the grep above covers every namespace.
- The whole scheme depends on one blackbox-exporter and one metric series. If every zeroscaler
  app looks down at the same time, suspect the metric path, not the apps. The chain is below.
- The apps never idle, because every HPA reads the same metric, and that metric is a NAS probe.
  All of them select `probe_success{job="blackbox-tcp"}` with no per-app label. `Probe/tcp` in
  `observability` has exactly one static target:
  `truenas.external-endpoints.svc.cluster.local:2049`. Nothing in the tree overrides
  `ZEROSCALER_JOB_NAME` or `ZEROSCALER_METRIC_NAME`. So the component is a gate on TrueNAS
  availability, not an idle-scaler. The apps stay at 1 while the NAS answers. One failed NFS
  probe scales all of them to zero together. Issue
  [#1901](https://git.dcunha.io/Exikle/home-infra/issues/1901) proposed to drop, fix or rename
  it. It was closed without a decision.
  Decision (2026-10-15, [#2767](https://git.dcunha.io/Exikle/home-infra/issues/2767)): leave it
  as it is. Do not drop it, do not add per-app probes, and do not rename it. The
  `HPAScaleToZero` feature gate in `kube/clusters/artemis/talos/controlplane.yaml.j2` stays. Do
  not open this again as cleanup.

### The wake-up path is a chain, and blackbox-exporter is only its first link

The HPA scales on an External metric, so the metric goes through the custom-metrics API:

```text
blackbox-exporter → vmagent → victoria-metrics-server → prometheus-adapter → HPA → Deployment
       probe_success{job="blackbox-tcp"} == 1  →  scale 0 → 1
```

`observability/prometheus-adapter` is the only provider of the
`v1beta1.external.metrics.k8s.io` APIService. If the adapter is unhealthy, every zeroscaler HPA
reads `<unknown>/1`. Every one of those apps then stays at zero, while the probes are green and
the exporter is fine. No alert fires for this. The fault reaches every app that the grep above
returns, across the cluster.

If everything in `media` is down, run these commands in this order:

```bash
kubectl get apiservice v1beta1.external.metrics.k8s.io    # AVAILABLE must be True
kubectl get hpa -n media                                  # TARGETS <unknown>/1 == adapter fault
kubectl get pods -n observability -l app.kubernetes.io/name=blackbox-exporter
```

## Critical Rules

- Never turn on "Remove Completed" in the download client settings of Sonarr or Radarr.
  cross-seed needs the files to stay.
- Prowlarr is the indexer source of truth. Never add indexer API keys directly to Sonarr,
  Radarr or Bazarr.
- cross-seed is built into qui. Do not deploy it as a separate app.
- The K-drama and C-drama routing lives in seerr, not in git. seerr knows only "normal" and
  "anime". So two Override Rules on the Sonarr service do the routing. TMDB original language
  `ko` goes to the Korean Dramas profile and `/media/kdrama`. `zh|cn` goes to the Chinese Dramas
  profile and `/media/cdrama`. seerr skips the rules for anime TV, so anime keeps its own route.
  To list the rules, call `GET /api/v1/overrideRule`.
- Recyclarr owns the quality profiles (`recyclarr/app/resources/recyclarr.yml`). The
  configuration refers to them by TRaSH `trash_id`, not by name. A reference by name silently
  stops matching when the guide renames a profile. For example, `SQP-1 (2160p)` became
  `[SQP] SQP-1 (2160p)`, and its scores went to 0.
- The SABnzbd incomplete directory is on the NFS media share
  (`/media/downloads/usenet/incomplete`). It is on the same filesystem as `complete`, so a
  finished job is a rename, not a copy across filesystems. A move to block storage needs a new
  volume, and it turns every unpack into a copy. Do not move it while jobs are queued.

## Internal Cluster DNS (pod-to-pod)

Always use the cluster-local DNS name, never an external one. The arr apps and qBittorrent
listen on `:80`, not on their upstream default ports. The app-template
`service.app.ports.http.port` anchor is `80` for all of them. If you connect one app to another
on the upstream default port, the connection is refused.

```text
http://sonarr.media.svc.cluster.local:80
http://radarr.media.svc.cluster.local:80
http://prowlarr.media.svc.cluster.local:80
http://qbittorrent.media.svc.cluster.local:80
http://bazarr.media.svc.cluster.local:80
http://qui.media.svc.cluster.local:80
http://seerr.media.svc.cluster.local:80
http://autobrr.media.svc.cluster.local:80
http://sabnzbd.media.svc.cluster.local:8080
http://trawl.media.svc.cluster.local:8191
http://immich.media.svc.cluster.local:2283
http://immich-ml.media.svc.cluster.local:3003
```

| App           | Correct port | Wrong (upstream default, and what old docs said) |
| ------------- | ------------ | ------------------------------------------------ |
| `sonarr`      | `80`         | `8989`                                           |
| `radarr`      | `80`         | `7878`                                           |
| `prowlarr`    | `80`         | `9696`                                           |
| `qbittorrent` | `80`         | `8080`                                           |
| `bazarr`      | `80`         | `6767`                                           |
| `autobrr`     | `80`         | `7474`                                           |
| `qui`         | `80`         | `7476`                                           |
| `seerr`       | `80`         | `5055`                                           |
| `sabnzbd`     | `8080`       | (none, `8080` is correct here)                   |

`:80` is not used by every app in this namespace. Only the apps above were normalized. Every
other app keeps its upstream port. So the guess `:80` fails as often as the guess `8989`:

| App                        | Port(s)                                  |
| -------------------------- | ---------------------------------------- |
| `silo`                     | `8080` native, `8096` jf, `9091` metrics |
| `paperless`                | `8000`                                   |
| `paperless-tika`           | `9998`                                   |
| `paperless-gotenberg`      | `3000`                                   |
| `bookboss`                 | `8080` http, `8081` grpc                 |
| `shelfmark`                | `8084`                                   |
| `komf`                     | `8085`                                   |
| `rensaio`                  | `9833`                                   |
| `thelounge`                | `9000`                                   |
| `trawl`                    | `8191`                                   |
| `audiobookshelf-app`       | `13378`                                  |
| `audiobookshelf-abs-tract` | `5555`                                   |
| `jelu`                     | `11111`                                  |

Before you connect an app, make sure of the port. The Service is the source of truth. The
anchor only tells you what was intended:

```bash
kubectl get svc -n media <app> -o jsonpath='{.spec.ports}'
```

`autobrr` and `qui` also expose a metrics port (`9094` and `8080`). The set of scraped apps
changes, so this file does not list it. To see which `media` apps are scraped, list the
`VMServiceScrape` objects:

```bash
kubectl get vmservicescrape -n media --context artemis
```

## SABnzbd Server Priority

The live `sabnzbd.ini` on the PVC is the source of truth. This table records the intent behind
the order. Do not use it as a snapshot of the live state.

| Priority | Server                 | Host                     |
| -------- | ---------------------- | ------------------------ |
| P0       | Frugal US              | news.frugalusenet.com    |
| P0       | Frugal EU              | eunews.frugalusenet.com  |
| P1       | NewsGroup Direct - 1TB | news.newsgroupdirect.com |
| P2       | Frugal Bonus           | bonus.frugalusenet.com   |
| P3       | Blocknews - 300GB      | usnews.blocknews.net     |

The two unlimited Frugal servers share P0 on purpose. SABnzbd uses the servers of one priority
in turn (round-robin). So US and EU work as one pool, and neither one is a fallback for the
other. The block accounts below them have a strict order. SABnzbd uses the metered accounts only
when an article is missing from the servers above.

The provider credentials are only in `sabnzbd.ini`, not in 1Password. The `sabnzbd` item in
1Password holds only the API keys.

## qBittorrent

There is no Gluetun sidecar and no VPN. The HelmRelease has a single `app` container. A
`grep -c gluetun` over the whole app directory returns 0. Torrent traffic leaves the cluster
directly through a second `LoadBalancer` Service (`service.bittorrent`). That Service is pinned
to `10.10.99.95` with `io.cilium/lb-ipam-ips`, and it sets `externalTrafficPolicy: Local`.

- Torrenting port: `31288` (`QBT_TORRENTING_PORT`, exposed on the `bittorrent` LB Service). UPnP
  is off in the app and on the UCG. The internet reaches the port only through a manual UCG port
  forward `31288 → 10.10.99.95`. The forward is kept on purpose for peer connections. It is not
  in OpenTofu.
- DHT, PeX and Local Peer Discovery are off (private trackers only).
- qui Automation applies the seeding rules in this order. Every delete rule removes only the
  torrent. Only the orphan scan below deletes files:
    1. qui removes a torrent that is unregistered on its tracker (`IS_UNREGISTERED`, for example
       "Torrent has been deleted.") and that seeded for ≥ 1 day. The day gives Sonarr and Radarr
       time to import.
    2. qui removes cross-seeds (tag `cross-seed`) after 7 days, at any ratio, linked to the
       library or not. Cross-seeds download nothing, so they have no hit-and-run requirement.
       The original sets the seed time. A cross-seed has no reason to seed after the original
       is done.
    3. qui removes originals on Luminarr, DigitalCore, Rastastugan, HD-Space and BakaBT with
       `HARDLINK_SCOPE = none` after 7 days, at any ratio.
    4. qui removes originals on every other tracker with `HARDLINK_SCOPE = none` at
       ratio ≥ 1.1 AND 7 days.
    5. qui pauses everything else at ratio ≥ 1.1 AND 7 days.

    The rules remove only the torrent for this reason. The qui action
    `deleteWithFilesPreserveCrossSeeds` finds shared files by an identical content path. An
    original with a folder layout and cross-seeds with a file layout of the same release (The
    Wind Rises, 2026-09-30) did not match. So the delete of the original took the data of the
    cross-seeds. The orphan scan reads every file path that each torrent refers to, so it cannot
    make that mistake.
    The trackers in rule 3 use time only, because ≤ 5 days of seeding satisfies the hit-and-run
    rule of each one (checked 2026-09-30). AvistaZ is not in the list. It needs 72h + 2h/GB,
    which is more than 7 days above about 48 GB. Add a new tracker to rule 3 only after you read
    its rules. To read the live automation rules, run `select row_to_json(a) from automations a`
    in the `qui` database.

- The qui orphan scan runs every day with auto-cleanup (60 min grace, ≤1000 files per run). It
  deletes files under the torrent save paths that no torrent refers to. It deletes anything that
  you put into `torrents/complete` by hand. If you delete a hardlinked file there, only the link
  in the download folder goes, and the library copy stays. Auto-cleanup does not run after a
  partial scan. A scan is partial when the save path of a torrent no longer exists. To unblock
  it, remove that torrent (its files are already gone).
- The global share limits in qBittorrent are off. qui does this work.
- qBittorrent carries `components/zeroscaler`. It does not idle out when nothing downloads. The
  HPA reads a shared `probe_success` metric, not the traffic of this app, and the app stayed at
  one replica the whole time. See § Scale-to-zero.

## autobrr

- A dropped IRC network does not come back without help. A tracker restarts its IRC services,
  and the reconnect fails (for example with `SASL negotiation failed`). autobrr then holds the
  network in an error state and never tries again. The `irc-watchdog` CronJob runs every 15 min
  (`app/resources/irc-watchdog.sh`). It uses its own API key, `AUTOBRR_WATCHDOG_API_KEY`, in the
  `autobrr` 1Password item. It restarts the networks that are unhealthy with a connection error.
  It fails if any network is still unhealthy after that. It never restarts a network that is only
  slow to join. A restart during a connect leaves the network stuck in `JoiningChannels`
  (“invalid state transition”), and only a pod restart clears that.
- Alert on the watchdog, not on the IRC metrics of autobrr.
  `autobrr_irc_channel_monitored_total` and `…_last_announced_timestamp_seconds` showed Luminarr
  as live through a 20-hour outage. `AutobrrIrcNetworkDown` fires when the watchdog has not
  passed for an hour. The `healthy` field of the API is the only reliable signal.
- Filters 1–3 exclude the categories that are not video (`except_categories`).

## Jellyfin (retired 2026-10-27)

Silo replaced Jellyfin (§ Silo). Silo serves `jellyfin.dcunha.io` with the server ID of
Jellyfin, so the existing apps continued to work without a new sign-in. The app, its Arc GPU
claim and autopulse were removed from the tree. The `jellyfin` kopiur snapshot lineage stays in
the repository (`kopiur.md` § deleting an app keeps the lineage). So you can still restore its
configuration. Do not deploy Jellyfin again to fix a gap in silo. Fix silo, or the gateway rule
in front of it.

## Silo

Silo replaced Jellyfin. Since 2026-10-27 it serves `jellyfin.dcunha.io`, together with its
native `silo.dcunha.io` and `silo-jf.dcunha.io`. All of its state is in shared Postgres
(`components/postgres/app`). So it has no PVC and no kopiur backup. If the pod is lost, nothing
is lost that is not in Postgres or that silo cannot make again.

- Images live on NFS, not on a PVC. Artwork and the bundled jellyfin-web are mounted from
  `/mnt/atlas/media/.silo/{artwork,compat}`. Artwork is trickplay, chapter images, TMDB/TVDB
  caches, and copies of sidecar posters and NFO images. Artwork filled a 10Gi miroir PVC in six
  days. Silo cannot serve the sidecar images of the arrs or the `.trickplay` folders of Jellyfin
  where they are. It always copies them or makes its own. So this space is not a duplicate by
  accident. The hidden `.silo` directory is outside every library root
  (`/media/{movies,tv,anime,kdrama,cdrama}`), so no scan reads it.
- `SECRET_KEY` is in 1Password (`infrastructure/silo`, field `SECRET_KEY`). It encrypts the JWT
  secret, the AI-provider keys and the push keys in the database. A Postgres restore is useless
  without it. Never make a new one.
- New files arrive by webhook. Sonarr and Radarr each have a "Silo" webhook into the built-in
  `silo.autoscan.arr-webhook` source of silo. The global autoscan switch must be on. If it is
  off, silo accepts the webhooks (202) and silently drops them. The full scan runs every night
  (`scanner.schedule` `0 4 * * *`). Real-time monitoring reports `unsupported_filesystem` on NFS
  and does nothing. autopulse did this job for Jellyfin, and it was retired with Jellyfin.
- Silo has its own edge rate-limit policy. `BackendTrafficPolicy/silo` overrides `network/edge`
  for the `silo-app` route. The login rule of the gateway matches `api/v1/auth/.*`. Without the
  override, that rule throttles TV sign-in (device polling every 3s) and token refresh. The
  override limits only `^/api/v2/auth/(login|device/start)$`. silo retired the v1 auth paths:
  `POST /api/v1/auth/login` returns `410 Gone` (checked 2026-11-18), so v1 needs no limit. The
  override copies the other fields of
  `edge`, because an override does not inherit them. If `edge` changes, change both.
  `mergeType: StrategicMerge` does not work here. It keeps the rule of the gateway beside the
  rule of the route.
- The gateway rewrites Jellyfin user IDs. Jellyfin clients send user IDs as 32 hex digits
  without dashes. The compat API of silo matches only the UUID with dashes. So `/Users/{id}/…`,
  `UserViews` and `Shows/NextUp` returned 404. `EnvoyExtensionPolicy/silo-jellyfin` runs a Lua
  filter on the `silo-jellyfin` route. The filter adds the dashes after `/Users/` and in
  `userId=`. The filter is Lua, because the regex rewrite of Envoy cannot change the query
  string. It works only because `extensionApis.enableLua: true` is set on the Envoy Gateway
  controller (off by default). Remove the policy when silo upstream accepts both forms.
- The Jellyfin takeover was done in these parts, so that no user had to sign in again:
    - Server identity: `jellyfin_compat.server_id` is the ID of Jellyfin, `server_name` is
      `Artemis`, and `public_url` is `https://jellyfin.dcunha.io`.
    - Logins: every Jellyfin device token became a `jellycompat_sessions` row with its own
      `auth_sessions` row. The silo JWTs in it are encrypted with the AAD
      `jellycompat_sessions:<column>:<token>`. `pseudo_user_id` is set to the old Jellyfin user
      ID, because the apps continue to call `/Users/<that id>`. A new login gets the derived ID
      of silo, `uuid5(3dfcc388-bf95-5572-bc16-7f1a375992dd, "<user id>:<profile id>")`.
    - Watch state: the admin history import of silo (source 1, one mapping per user).
    - Play counts: the Playback Reporting rows were copied into `admin_playback_history`, with
      the prefix `jfimport-` on `session_id`.
    - Passwords: they did not carry over. Silo verifies only bcrypt, and Jellyfin stores
      PBKDF2-SHA512.
- Seerr signs users in through silo. So the `jellyfinUserId` of each Seerr user is the derived
  ID of silo. The silo session that Seerr holds for that user was moved to the same ID. The
  media server of Seerr is `silo.media.svc.cluster.local:8096`, which uses the `sa_` API key of
  silo.
- The settings live in the database. You change them through the admin API
  (`/api/v2/admin/...`, key in `infrastructure/silo/API_KEY`). A `PUT` needs `If-Match` with the
  ETag from a `GET`. The transcode scratch space is `/tmp/silo-transcode`, on an emptyDir with a
  30Gi limit.
- Requests made in silo go to Seerr through the `silo.requests.seerr` plugin, in
  `requester_mode: mapped`. The plugin matches each requester to a Seerr user by email. So the
  Seerr user emails are kept equal to the silo emails, and the per-user permissions of Seerr
  decide approval. When a requester has no Seerr user, the plugin creates one with no password.
  Seerr allows that only while its email agent is on. So email is on, against an SMTP host that
  does not exist (`127.0.0.1:25`). The password and notification mails fail and are logged.
  Nothing is sent.
- GPU: the Arc A380 through a DRA claim (`ResourceClaimTemplate/silo-gpu`). Silo took the claim
  over from Jellyfin when Jellyfin was retired. So silo runs on `talos-gpu-01`. See `gpu.md`.

## seerr (formerly Jellyseerr)

The app was renamed. The directory is `kube/clusters/artemis/apps/media/seerr/`, the image is
`ghcr.io/seerr-team/seerr`, and there is no `jellyseerr` directory. Anything that still says
"Jellyseerr" is stale. The `ai-general` MCP tools also show as `seerr_*`.

- One HTTPRoute carries both `seerr.dcunha.io` and `requests.dcunha.io`. It is attached to
  `edge-gateway`. The Service port is `80`.
- Tag Requests is on (tags go to Sonarr and Radarr).
- The Streamyfin push webhook is off. It posted to the Streamyfin plugin inside Jellyfin, which
  was removed with Jellyfin. silo has no equivalent endpoint.

## Data layer

Media apps that need a real database use the shared services in `database`, not their own. See
`.agents/references/postgres-dragonfly.md`.

| App         | Postgres                  | Dragonfly index |
| ----------- | ------------------------- | --------------- |
| `paperless` | shared, via `postgres-rw` | 1               |
| `bookboss`  | shared, via `postgres-rw` | —               |
| `trawl`     | —                         | 5               |

## TrueNAS NFS

- Server: `10.10.99.100` | Path: `/mnt/atlas/media`
- Pods mount it at `/media`.
- The NFS share sets `mapall_user = "kubernetes"` and `mapall_group = "kubernetes"` (UID 1000)
  in `terraform/stacks/truenas/nfs.tf`. So every write lands on the NAS as UID 1000.
- `rensaio` is the exception in the pod. It runs as PUID 99 / PGID 100.

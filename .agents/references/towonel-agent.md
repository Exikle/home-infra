# towonel Agent — home-infra

This file explains how the public internet reaches Artemis. Issue #3082 holds the decision and its
history. `towonel.md` and `oci-networking.md` (§ The front door) document the frostlink side.

## What the agent does (Shape 1)

Artemis publishes no hostname through towonel. The Envoy on frostlink terminates TLS for every
public name and runs CrowdSec. It then encrypts the traffic again and sends it to Artemis over one
towonel TCP service.

| Part           | Value                                                                |
| -------------- | -------------------------------------------------------------------- |
| Service name   | `artemis-backhaul`                                                   |
| Edge port      | `15001`                                                              |
| Origin         | `edge-gateway.network.svc.cluster.local:443`                         |
| Defined in     | `TOWONEL_AGENT_TCP_SERVICES` in `towonel-agent/app/helmrelease.yaml` |
| frostlink side | the `home-backhaul` app in the `towonel` namespace on frostlink      |

The agent connects out over iroh QUIC (UDP 51820 on frostlink) and keeps the connection open.
Artemis opens no inbound port.

- No hostname claims. The agent has no `TOWONEL_AGENT_SERVICES`. frostlink sends all of
  `*.dcunha.io` and `dcunha.io` to the backhaul.
- No PROXY protocol. The backhaul carries HTTPS that Envoy encrypts again. The real client IP is in
  `X-Forwarded-For`, which the Envoy on frostlink sets.
- `ClientTrafficPolicy/edge` must trust that header. It trusts `X-Forwarded-For` from
  `10.42.0.0/16`, the agent pod CIDR. Without this, every request seems to come from the agent. The
  per-IP rate limits then limit everyone at once.
- No CrowdSec on Artemis. A `403` or a challenge page on a public site comes from the CrowdSec on
  frostlink. Fix it on Frostlink (`crowdsec.md`). LAN traffic is not checked.
- SNI on the backhaul. frostlink validates the Artemis certificate with SNI `edge.dcunha.io`. For
  the apex, it uses `dcunha.io`, because `edge-gateway` has a separate apex listener.

The agent is app-template (`git.ow-ops.eu/towonel/towonel-agent` image), not the upstream chart. Its
configuration is `TOWONEL_AGENT_*` environment variables plus `TOWONEL_INVITE_TOKEN`. To find the versions, run
`grep -h 'tag:' kube/clusters/artemis/apps/network/towonel-agent/app/*.yaml`.

Both clusters live in this repo. The interface between the two towonel sides is one invite token
and the backhaul port.

## Which gateway a route uses

`edge-gateway` is the list of _public_ Artemis apps. Public hostnames and LAN DNS (`10.10.99.90`,
LAN name `edge.dcunha.io`) both reach it. Never point the backhaul at `internal-gateway`.

| Hostname                | `parentRefs`       | `sectionName`           |
| ----------------------- | ------------------ | ----------------------- |
| `*.dcunha.io`, public   | `edge-gateway`     | `https-dcunha`, or none |
| `dcunha.io` apex        | `edge-gateway`     | `https-dcunha-apex`     |
| `*.dcunha.io`, LAN only | `internal-gateway` | `https`, or none        |

`external-gateway` takes no new routes.

The `sectionName: https` trap works like this. On `internal-gateway` and `external-gateway`,
`https` is the `dcunha.io` listener. On `edge-gateway`, `https` is the `frostlink.dev` listener. So
a `*.dcunha.io` route that pins `sectionName: https` never attaches. Use `https-dcunha`. Auth
SecurityPolicies (tinyauth, envoy-oidc) target the HTTPRoute, so they follow the route.

## Certificates

Public visitors see the frostlink certificate. Only two parties see the Artemis certificates:
frostlink, which checks them over the backhaul, and LAN clients. So a certificate problem on a
public name belongs to frostlink, unless the backhaul check fails.

`frostlink-dev-tls` in `network` is imported from 1Password. It is not issued here. Copy the shape
from `certificates/import/frostlink-externalsecret.yaml`. Do _not_ copy it from the neighbouring
`externalsecret.yaml`. The two imports differ:

- The frostlink import keeps the ExternalSecret defaults (`refreshInterval` 1h,
  `creationPolicy: Owner`). So it picks up renewals.
- The `dcunha-io-tls` import is only for bootstrap (`refreshPolicy: CreatedOnce`,
  `creationPolicy: Orphan`). cert-manager owns its renewal.

If you copy the `dcunha-io-tls` pattern onto the frostlink import, it serves an expired certificate
at the next rollover. cert-manager does not manage the imported secret, so the cert-manager expiry
metrics do not cover it.

## DNS

The records for the public names are grey, and they point at `edge.frostlink.dev`. The Envoy on
frostlink answers there. A proxied record sends the connection to Cloudflare instead.

- dcunha.io: `external-dns-edge` (`kube/clusters/artemis/apps/network/edge-dns/`) writes one grey
  CNAME for each `edge-gateway` route. It reads only `edge-dns.kubernetes.io/` annotations
  (`--annotation-prefix`). So `external-dns-unifi` can keep the standard
  `external-dns.kubernetes.io/target: edge.dcunha.io` for the LAN. To see the configuration, run
  `kubectl get deploy -n network external-dns-edge -o yaml --context artemis`.
- status.dcunha.io: a grey CNAME to `edge.frostlink.dev`, from `cloudflare-dns/app/dnsendpoint.yaml`.
  The Envoy on frostlink serves it.
- edge.dcunha.io: a grey CNAME to `edge.frostlink.dev`, from `towonel-agent/app/dnsendpoint.yaml`.
  It exists for IPv6 LAN clients (`networking.md` § VLANs, the LAN-side AAAA leak).
- frostlink.dev: frostlink owns its own records (`oci-networking.md` § The `frostlink.dev` zone is
  shared with Artemis, which wins). `external-dns-frostlink` (`network/frostlink-dns`) still runs
  on Artemis, with `crd` as its only source.
- Grey records and `providerSpecific` on a `DNSEndpoint`: `oci-networking.md` § DNS, which wins.
- Check with `@1.1.1.1`. A bare `dig` on the dev machine returns the split-horizon (LAN) answer.

### The collision guard

This section owns the rule. `oci-networking.md` links here.

The external-dns on frostlink runs `policy: sync` with `txtOwnerId: frostlink` over the
`frostlink.dev` zone. A second controller on that zone must differ in _both_ the owner id and the
TXT prefix. If not, the two controllers delete each other's records in a loop:

```yaml
txtOwnerId: artemis # not frostlink
txtPrefix: k8s.artemis.%{record_type}- # not frostlink's prefix
```

The owner id decides what a controller deletes. The prefix decides whether a controller can see
the ownership TXT records of the other controller. Matching prefixes with different owner ids cause
the loop, because the controllers overwrite each other's registry entries. The
`external-dns-cloudflare` on frostlink uses `k8s.%{record_type}-`. That is the same prefix as the
`external-dns-cloudflare` of Artemis (owner `artemis-cluster`). Leave out `--cloudflare-proxied` on
the instance for the frostlink zone, so that records are grey by default.

## Getting an invite token

The frostlink hub issues the token. Run this from a session that has access to frostlink:

```bash
mise run --yes //kube/clusters/frostlink:towonel-invite artemis --tcp-ports 15001
```

The task and the port grant are in `towonel.md` § Operating, which wins.

The `token` (`tt_inv_2_…`) in the response is the only secret. It contains the hub identity, so the
agent needs no hub URL. To revoke it, call `DELETE /v1/invites/{invite_id}`.

The user must create the 1Password item. `op item create` from an agent session returns
`(101) You do not have permission`. The item lives in the `artemis` vault, in item `towonel`,
field `TOWONEL_INVITE_TOKEN`. The ExternalSecret is inline under `externalSecrets.env` in the
HelmRelease (`dataFrom.extract.key: towonel`). The agent reads it as a `secretKeyRef` on
`TOWONEL_INVITE_TOKEN`.

## Shape

`kube/clusters/artemis/apps/network/towonel-agent/` holds `ks.yaml`, plus `app/` with
`ocirepository.yaml`, `helmrelease.yaml` and `dnsendpoint.yaml`. The agent is stateless: no PVC and
no kopiur. The invite token is all of its state.

app-template does not inherit the hardening of the chart, so the HelmRelease writes it out. These
are the health settings:

- Health is `/healthz` on port 9090.
- The startup probe allows 60 failures, because the agent can take some time to set up the iroh
  connection.
- Liveness uses `timeoutSeconds: 3`. A 1 s timeout is too tight and causes restarts with no real
  fault.

Write the manifests without comments (`yaml-conventions.md`).

Memory is sized for bursts, not for idle. The agent idles near 25–50Mi, but it buffers every stream
that it relays. When a peer pushes an image, apoci federation opens one download per layer (2–3 per
digest). An image of about 10 layers pushed the agent past an old 128Mi limit. Each OOM restart
dropped every public connection for a few seconds. The apoci on frostlink then logged
`eager replication failed … EOF` for every blob in flight. At 512Mi, a parallel pull of 19 blobs
(about 400MB) ran clean (2026-10-27). If it OOMs again, raise the limit. Do not throttle apoci. Its
replication concurrency cannot be configured. Since Shape 1, _all_ public traffic goes through this
one agent. So an OOM now drops every public Artemis connection.

## Other TCP and UDP services

`TOWONEL_AGENT_TCP_SERVICES` holds only `artemis-backhaul`. `minecraft` (25565/tcp) and `eco`
(3000/udp) were removed with their apps. To add a service, use this entry shape:

`{"name":"<name>","origin":"<service>.<namespace>.svc.cluster.local:<port>","listen_port":<port>}`

UDP entries also take `idle_timeout_secs`, and they go in `TOWONEL_AGENT_UDP_SERVICES`.

- Such a service does not go through `edge-gateway`. The agent connects to the app Service
  directly.
- The edge binds the host port only while an agent session exists. So if the agent is down, a port
  test proves nothing.
- The invite must grant the port (`towonel.md` § Operating). The OCI security list on frostlink
  must also allow it.

## Jellyfin — the video path

`jellyfin.dcunha.io` goes through the Envoy on frostlink and the backhaul. The Cloudflare terms
forbid serving video over the CDN. Every record is grey, so no Jellyfin traffic touches Cloudflare.

The `jellyfin_compat.public_url` of silo is pinned to the `dcunha.io` hostname. So the
unauthenticated `/System/Info/Public` endpoint returns `LocalAddress: https://jellyfin.dcunha.io`
to public clients. The home IP is not exposed. This is accepted. If the URL points at another
hostname, LAN clients go out to the VPS and back. The residential upload speed then limits local
playback.

Bandwidth: the egress budget is in `oci-networking.md` § Egress budget alerts, which wins. For
Jellyfin, the real limit is the residential upload of Artemis (about 20–50 Mbps). Expect seeking to
feel worse than direct play.

## Gotchas

- If agents reach the hub through the relay but never connect directly, suspect the UDP 51820 rule
  (`oci-networking.md` § Oracle Cloud VCN, which wins).
- The default relay is the one that the hub advertises. Set `relayUrl` only to override it.
- The pre-commit hook rewrites `$schema` in `kustomization.yaml` to
  `k8s-schemas.home-operations.com`, and it stages the rewrite. Never use `--no-verify`.
- If the agent is down, the frostlink `home-down` page answers `503` for every `dcunha.io` name.

## Verify

1. Make sure that `towonel_edge_active_sessions` on the frostlink edge is at least 1 while the
   agent runs.
2. Make sure that the frostlink `TowonelEdgeNoSessions` alert (`app/prometheusrule-edge.yaml`) is
   on. It is the only alert for a dead tunnel. Leave it on.
3. Run `curl -sI https://<name>.dcunha.io` from outside. Make sure that it answers and that the
   certificate is the frostlink one.

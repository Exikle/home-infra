# Reference: towonel — Frostlink

towonel exposes HTTP(S) services that sit behind NAT/CGNAT without opening inbound
ports **at the origin** — the edge itself very much does listen inbound, on this host.
Frostlink runs the **hub** (control plane) and the **edge** (public listener); the
Artemis agent dials in and has been connected since 2026-08-19. A second agent,
Frostlink's own `network/towonel-agent`, carries `headscale.frostlink.dev`.

The agent side — which hostnames Artemis claims, how it maps them to its own
`edge-gateway`, and the PROXY-protocol contract — is documented in the **Artemis** repo at
`.agents/references/towonel-agent.md`. The two files describe two ends of one tunnel; when
they disagree about a port, a DNS record, or who terminates TLS, one of them is wrong.

Upstream: <https://codeberg.org/towonel/towonel> · charts `oci://codeberg.org/towonel/charts/`

## Shape here

One `towonel-node` release with **both roles enabled**, in its own `towonel` namespace.

| Thing       | Value                                                   |
| ----------- | ------------------------------------------------------- |
| Chart       | `oci://codeberg.org/towonel/charts/towonel-node`        |
| Namespace   | `towonel` (not `network` — see below)                   |
| Workload    | hostNetwork **DaemonSet** (an enabled edge forces this) |
| Edge public | `edge.frostlink.dev` → `40.233.88.33`, **DNS-only**     |
| Hub API     | `hub.frostlink.dev` via cloudflared + Envoy             |
| State       | sqlite on a kopiur-backed PVC                           |
| TLS         | passthrough — **nothing here terminates it**            |

### Nothing on this cluster terminates TLS for a tunnelled hostname

The edge peeks at SNI on a raw TLS connection and forwards the bytes. For
`jellyfin.frostlink.dev`, `eco.frostlink.dev` and `echo.frostlink.dev`, the certificate the
public sees is **Artemis's own copy** of `*.frostlink.dev` — a separate issuance with its own
key, imported from 1Password onto Artemis's `edge-gateway`. This cluster's `frostlink-dev-tls`
is never presented for those names. The same passthrough carries Artemis's `dcunha.io` names —
`git.dcunha.io` and `registry.dcunha.io` are CNAMEs to `edge.frostlink.dev` — whose certificate
also lives on Artemis.

Two consequences worth holding on to:

- A certificate problem on a tunnelled hostname is an **Artemis** problem. Renewing the cert
  here does not fix it, and cert-manager's expiry metrics on this cluster do not cover it.
- A frostlink-issued cert appearing on a tunnelled hostname means the edge stopped passing
  through and started terminating — a real misconfiguration, not a cosmetic one.

### The edge sends a PROXY protocol v2 header, and Artemis requires it

Passthrough services prepend a HAProxy **PROXY protocol v2** header by default
(`proxy_protocol` defaults to `v2` for HTTPS services, `none` for TCP services). Artemis leaves
that default in place and pairs it with `ClientTrafficPolicy/edge` on its `edge-gateway`, which
sets `proxyProtocol.optional: false`.

That is why real client IPs survive the tunnel — verified 2026-08-22, the Artemis agent logs a
public client address per stream. It also means **the two ends are coupled**: turning the header
off on one side without the other produces a TLS-shaped failure (`tlsv1 alert protocol version`,
`Broken pipe`) that points nowhere near the cause. Nothing on this side needs changing to keep it
working; just do not assume the header is off.

## Why its own namespace

The edge is a hostNetwork DaemonSet binding host `:443` and `:80`. PodSecurity
`baseline` forbids both host namespaces and hostPorts, and `network` has no PSS
label so it inherits `baseline`. Labelling `network` privileged would also relax
envoy-gateway, cloudflared and external-dns, so towonel gets its own namespace at
`pod-security.kubernetes.io/enforce: privileged` — same pattern as `cert-manager`,
`observability` and `openebs-system`.

## Why the hub API is not exposed directly

The hub speaks **plain HTTP** on `:8443` unless `TOWONEL_HUB_TLS_ACME_EMAIL` is set,
and that path is ACME **TLS-ALPN-01**, which Let's Encrypt only validates on port
443 — which the edge owns. There is no static-certificate option: `hub_tls_cert_dir`
is ACME `FileStorage`, not a place to drop an existing cert.

So the hub is published as an `HTTPRoute` on `external-gateway`, where Envoy
terminates TLS with the existing `*.frostlink.dev` certificate and cloudflared
carries the traffic. **TCP 8443 must stay closed on the OCI security list** — it is
bound on the host by hostNetwork, so an open rule exposes the operator API in
cleartext.

## Why sqlite and not the CNPG cluster

The hub supports `postgres`, but:

- Coupling the tunnel control plane to Postgres means a Renovate CNPG image bump
  can take **ingress** down. That failure mode already cost us the mautrix bridges
  (see `references/database.md`).
- The Postgres advisory lock only matters for multi-replica hub HA, and a single
  node cannot have that.
- The node already needs a persistent volume for its keys, so sqlite adds no new
  state to back up.

## The data volume is not optional

`/data` holds `node.key` (edge identity), `hub_kek.key` (seals hub signing keys) and
`invite_hash.key`. **Losing `invite_hash.key` invalidates every outstanding invite.**

The chart's `templates/_config.tpl` forces the volume to `emptyDir` unless
`persistence.data.type` is set explicitly — `existingClaim` alone is silently
ignored and the keys regenerate on every restart. Always set both:

```yaml
persistence:
    data:
        type: persistentVolumeClaim
        existingClaim: towonel
```

Do not add `globalMounts`/`advancedMounts`; the chart supplies a mount at
`edge.dataDir` and a second one double-mounts the volume.

## kopiur movers need an explicit security context

Both patches live in `kubernetes/apps/towonel/towonel/app/kustomization.yaml`, and
the component is pulled in **there** rather than via the Flux Kustomization's
`components:` — patches in the app kustomization do not apply to resources a Flux
`spec.components` introduces.

| Mover   | Component default                        | Why it fails                                                                                                                                        |
| ------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Restore | `inheritSecurityContextFrom.snapshot`    | A first deploy has no recorded snapshot → `MissingRecordedIdentity`, the Restore holds, and the PVC never binds (the Restore is its populator).     |
| Backup  | `inheritSecurityContextFrom.pvcConsumer` | Inherits `NET_BIND_SERVICE` from the edge; kopiur treats any added capability as a privileged mover and refuses it (`PrivilegedMoverNotPermitted`). |

Both are patched to a plain non-root context (uid/gid `10001`, matching the chart)
rather than annotating the namespace for privileged movers.

Target the patches **by kind**, not by name — `postBuild` substitution runs after
kustomize, so the resources are still literally named `${KOPIUR_APP}`.

## DNS must be grey-cloud, and the annotation does not work

towonel routes by peeking at SNI on a raw TLS connection, so `edge.frostlink.dev`
must resolve to the VPS itself. A proxied record hands the connection to Cloudflare,
which terminates TLS and cannot forward it.

external-dns runs with a global `--cloudflare-proxied`, so this needs a per-record
override. On the **CRD source an annotation on the DNSEndpoint is ignored** — it has
to be `providerSpecific` on the endpoint:

```yaml
providerSpecific:
    - name: external-dns.alpha.kubernetes.io/cloudflare-proxied
      value: "false"
```

Verify with `dig +short edge.frostlink.dev @1.1.1.1` — a `172.64.x.x` answer means
it is still proxied and SNI routing will not work.

**The `*.frostlink.dev` wildcard is a second grey record, and it is not ours.** Artemis publishes
it (a CNAME to `edge.frostlink.dev`) from its own `external-dns-frostlink` instance, owner id
`artemis`. Two consequences: any hostname on this cluster that lacks an explicit record falls
through the wildcard to Artemis's edge, and this cluster's external-dns must never be repointed at
owner id `artemis` or prefix `k8s.artemis.%{record_type}-` — see `networking.md` § The
`frostlink.dev` zone is shared with Artemis.

## Ports

Two kinds: ports the DaemonSet declares and holds for its lifetime, and ports the edge binds
**on demand** when an agent registers a TCP/UDP service.

### Static — declared on the DaemonSet

| Port      | Proto | Where            | Open on OCI?                                                                   |
| --------- | ----- | ---------------- | ------------------------------------------------------------------------------ |
| 443       | TCP   | edge TLS (SNI)   | **yes**                                                                        |
| 51820     | UDP   | iroh QUIC        | **yes**                                                                        |
| 8443      | TCP   | hub API          | **no** — via cloudflared                                                       |
| 80        | TCP   | edge HTTP        | **yes** (2026-10-04) — forwards by `Host` to the origin's `:80`, for redirects |
| 51444     | TCP   | hub↔edge link    | no — single pod, disabled                                                      |
| 9090/9091 | TCP   | edge/hub metrics | no — scraped in-cluster                                                        |

Missing the UDP half fails **silently**: QUIC never establishes and there is no error.

### Dynamic — bound per agent service, absent from the DaemonSet spec

| Port  | Proto | Service     | Origin                         |
| ----- | ----- | ----------- | ------------------------------ |
| 25565 | TCP   | `minecraft` | Artemis, via the towonel agent |
| 3000  | UDP   | `eco`       | Artemis, via the towonel agent |

These are real public listeners on this host, and they are invisible in
`kubectl get ds -n towonel towonel -o yaml` — the `ports:` list stops at 9091. The edge logs
them instead:

```text
edge tcp listener bound   port=25565 service=minecraft
edge udp listener bound   port=3000  service=eco
unbinding udp listener    port=3000  service=eco      # on session loss
```

Three things follow:

- **They exist only while an agent session does.** Probing the port while the agent is down
  proves nothing, and an OCI rule change cannot be validated against a disconnected edge.
- **The OCI security list must allow them**, and it does (console-verified 2026-10-04 —
  `networking.md` § Oracle Cloud VCN).
- **25565 attracts constant internet scanning.** A steady trickle of
  `client->agent forward: Connection reset by peer (os error 104)` / `Connection timed out
(os error 110)` on `route_key: tcp:minecraft` is background noise, not a fault.

## Monitoring

The chart ships hub alerts (`monitoring.prometheusRule.enabled`) and a
ServiceMonitor; vm-operator's prometheus converter turns both into `VMRule` /
`VMServiceScrape`, and vmalert has `selectAllByDefault: true`. Edge alerts are **not**
in the chart — they are lifted from `eleboucher/homelab` into
`app/prometheusrule-edge.yaml` with the upstream `cluster="towonel-ops"` selector
dropped (that exists only because their hub runs outside their cluster).

`TowonelEdgeNoSessions` was omitted while there were no agents; it was **enabled 2026-08-19**
when the Artemis agent landed, and zero sessions stopped being a valid steady state. Leave it
on. It is the only alert that catches a dead tunnel for the non-HTTP services — Artemis probes
its own HTTPS hostnames, so those fail loudly, but `minecraft/tcp` and `eco/udp` would
otherwise go dark silently. The `for: 10m` tolerates an agent rollout without flapping.

## Operating

```bash
# health
kubectl -n towonel logs ds/towonel --tail=50
curl -s https://hub.frostlink.dev/v1/readyz            # {"status":"ok"}

# is the hub the active leader? (should be 1)
kubectl -n towonel run q --rm -i --restart=Never --image=mirror.gcr.io/curlimages/curl \
  --command -- curl -s http://towonel.towonel.svc.cluster.local:9091/metrics \
  | grep towonel_hub_is_leader

# how many agents are attached? (should be 2 — Artemis + the local network/towonel-agent for headscale)
kubectl -n towonel logs ds/towonel --tail=200 | grep 'agent session'

# edge reachable directly, and rejecting SNI no agent claims
openssl s_client -connect 40.233.88.33:443 -servername nope.frostlink.dev </dev/null

# on-demand backup of the key material
just kube backup towonel towonel
```

Creating an invite for an agent uses the operator API key that the node generates into `/data`
(`/data/operator.key`); the hub API is at `https://hub.frostlink.dev`. **The invite carries the
port grants**, not just the hostnames — Artemis's agent claims `*.frostlink.dev`, `*.dcunha.io`
and `dcunha.io` (its `towonel-agent/app/helmrelease.yaml`), so its invite covers all three plus
`tcp_ports: [25565]` and `udp_ports: [3000]`. Frostlink's own `network/towonel-agent` claims only
`headscale.frostlink.dev`. Adding a TCP/UDP service on the agent side without
a matching grant leaves the edge declining to bind the listener, with no error on either side.

## Gotchas

- **`helm show chart oci://codeberg.org/towonel/charts/towonel` 404s** — the chart is
  `towonel-node` (hub and/or edge); the agent chart is `towonel-agent`.
- **The chart's derived probes use `timeoutSeconds: 1`** — the same too-tight setting
  that let a brief Postgres blip kill the mautrix bridges. They are loosened in the
  HelmRelease; do not let a chart bump quietly reset them.
- **`edge_link listen_addr and psk must both be set; edge_link disabled`** is expected
  and harmless here — that link only matters for remote edges in other regions.
- **`Insecure TLS config: server certificates will be trusted without verification`**
  comes from `iroh_relay::tls` on startup. It is the iroh relay client's default and
  is not towonel's public TLS path.

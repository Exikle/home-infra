# Reference: towonel — Frostlink

towonel exposes HTTP(S) services that sit behind NAT/CGNAT without opening inbound
ports at the origin. Frostlink runs the **hub** (control plane) and the **edge**
(public listener); agents run elsewhere (Artemis) and dial in.

Upstream: <https://codeberg.org/towonel/towonel> · charts `oci://codeberg.org/towonel/charts/`

## Shape here

One `towonel-node` release with **both roles enabled**, in its own `towonel` namespace.

| Thing        | Value                                                   |
| ------------ | ------------------------------------------------------- |
| Chart        | `oci://codeberg.org/towonel/charts/towonel-node`        |
| Namespace    | `towonel` (not `network` — see below)                   |
| Workload     | hostNetwork **DaemonSet** (an enabled edge forces this) |
| Edge public  | `edge.frostlink.dev` → `40.233.88.33`, **DNS-only**     |
| Hub API      | `hub.frostlink.dev` via cloudflared + Envoy             |
| State        | sqlite on a kopiur-backed PVC                           |
| TLS          | passthrough (origins keep their own certs)              |

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

| Mover   | Component default                | Why it fails                                                                                       |
| ------- | -------------------------------- | -------------------------------------------------------------------------------------------------- |
| Restore | `inheritSecurityContextFrom.snapshot` | A first deploy has no recorded snapshot → `MissingRecordedIdentity`, the Restore holds, and the PVC never binds (the Restore is its populator). |
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

## Ports

| Port      | Proto | Where            | Open on OCI? |
| --------- | ----- | ---------------- | ------------ |
| 443       | TCP   | edge TLS (SNI)   | **yes**      |
| 51820     | UDP   | iroh QUIC        | **yes**      |
| 8443      | TCP   | hub API          | **no** — via cloudflared |
| 80        | TCP   | edge HTTP/ACME   | no — origins use DNS-01 |
| 51444     | TCP   | hub↔edge link    | no — single pod, disabled |
| 9090/9091 | TCP   | edge/hub metrics | no — scraped in-cluster |

Missing the UDP half fails **silently**: QUIC never establishes and there is no error.

## Monitoring

The chart ships hub alerts (`monitoring.prometheusRule.enabled`) and a
ServiceMonitor; vm-operator's prometheus converter turns both into `VMRule` /
`VMServiceScrape`, and vmalert has `selectAllByDefault: true`. Edge alerts are **not**
in the chart — they are lifted from `eleboucher/homelab` into
`app/prometheusrule-edge.yaml` with the upstream `cluster="towonel-ops"` selector
dropped (that exists only because their hub runs outside their cluster).

`TowonelEdgeNoSessions` is deliberately omitted while there are no agents — zero
sessions is the correct steady state until the Artemis agent lands. Re-enable it then.

## Operating

```bash
# health
kubectl -n towonel logs ds/towonel --tail=50
curl -s https://hub.frostlink.dev/v1/readyz            # {"status":"ok"}

# is the hub the active leader? (should be 1)
kubectl -n towonel run q --rm -i --restart=Never --image=mirror.gcr.io/curlimages/curl \
  --command -- curl -s http://towonel.towonel.svc.cluster.local:9091/metrics \
  | grep towonel_hub_is_leader

# edge reachable directly, and rejecting unknown SNI (expected with no agents)
openssl s_client -connect 40.233.88.33:443 -servername nope.frostlink.dev </dev/null

# on-demand backup of the key material
just kube backup towonel towonel
```

Creating an invite for an agent (S8) uses the operator API key that the node
generates into `/data`; the hub API is at `https://hub.frostlink.dev`.

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

# Reference: towonel — Frostlink

towonel is the private path between the public front door and Artemis. Frostlink runs the **hub**
(control plane) and the **edge**; the Artemis agent dials in over UDP 51820. Public web traffic does
**not** go through the edge any more: Envoy owns the node's public 80 and 443 (`oci-networking.md` §
The front door, Artemis issue #3082). The edge carries agent tunnels and the TCP backhaul to Artemis.

The agent side is Artemis's `.agents/references/towonel-agent.md`. The two files
describe two ends of one tunnel; when they disagree about a port, a DNS record, or who terminates
TLS, one of them is wrong. Frostlink no longer runs an agent of its own.

Upstream: <https://codeberg.org/towonel/towonel> · charts `oci://codeberg.org/towonel/charts/`

## Shape here

One `towonel-node` release with **both roles enabled**, in its own `towonel` namespace.

| Thing       | Value                                                   |
| ----------- | ------------------------------------------------------- |
| Chart       | `oci://codeberg.org/towonel/charts/towonel-node`        |
| Namespace   | `towonel` (not `network` — see below)                   |
| Workload    | hostNetwork **DaemonSet** (an enabled edge forces this) |
| Edge public | `edge.frostlink.dev` → `40.233.88.33`, **DNS-only**     |
| Hub API     | `hub.frostlink.dev` via Envoy                           |
| State       | sqlite on a kopiur-backed PVC                           |

Hub and edge share one process because a single node has nowhere to place a separate edge; the
split exists only to run edges in other regions. `TOWONEL_HUB_PUBLIC_URL` is where agents reach the
control plane (through Envoy, not the raw 8443 listener); `TOWONEL_EDGE_ADVERTISED_ADDRESSES`
is where they dial the edge and must be the DNS-only A record. The edge's `/data` needs only the
key files and the sqlite DB, so the 1Gi `KOPIUR_CAPACITY` is ample. The node's public IP in
`FROSTLINK_PUBLIC_IP` is not a secret.

### The backhaul to Artemis

Artemis's agent publishes **one** TCP service, `artemis-backhaul`, on edge port 15001. It lands on
Artemis `edge-gateway:443`. `kube/clusters/frostlink/apps/towonel/home-backhaul` holds the Frostlink half:
Services `artemis-backhaul` and `artemis-backhaul-apex` (both to the towonel pod on `:15001`),
BackendTLSPolicies, HTTPRoutes for `*.dcunha.io` and `dcunha.io`, and a BackendTrafficPolicy with a
TCP health check and the `home-down` page. How it works and why: `oci-networking.md` § The front door.

- Envoy terminates the public TLS, then re-encrypts to Artemis. The edge never sees plaintext and
  does no SNI routing for public names.
- There is **no PROXY protocol** and no hostname claim. The real client IP travels in
  `X-Forwarded-For`; Artemis `ClientTrafficPolicy/edge` trusts it from the agent pod.
- A certificate problem on a public `dcunha.io` name is split: the browser sees Frostlink's
  certificate, and Envoy checks Artemis's. A failed check surfaces as the `home-down` page.

## Why its own namespace

The edge is a hostNetwork DaemonSet binding host `:443` and `:80`. PodSecurity
`baseline` forbids both host namespaces and hostPorts, and `network` has no PSS
label so it inherits `baseline`. Labelling `network` privileged would also relax
envoy-gateway and external-dns, so towonel gets its own namespace at
`pod-security.kubernetes.io/enforce: privileged` — same pattern as `cert-manager`,
`observability` and `openebs-system`.

## Why the hub API is not exposed directly

The hub speaks **plain HTTP** on `:8443` unless `TOWONEL_HUB_TLS_ACME_EMAIL` is set,
and that path is ACME **TLS-ALPN-01**, which Let's Encrypt only validates on port
443 — which the edge owns. There is no static-certificate option: `hub_tls_cert_dir`
is ACME `FileStorage`, not a place to drop an existing cert.

So the hub is published as an `HTTPRoute` on `external-gateway`, where Envoy
terminates TLS with the existing `*.frostlink.dev` certificate. **TCP 8443 must stay closed on the OCI security list** — it is
bound on the host by hostNetwork, so an open rule exposes the operator API in
cleartext.

## Why sqlite and not the CNPG cluster

The hub supports `postgres`, but:

- Coupling the tunnel control plane to Postgres means a Renovate CNPG image bump
  can take **ingress** down. That failure mode already cost us the mautrix bridges
  (see `database.md` § Why clients must tolerate a primary change).
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

Both patches live in `kube/clusters/frostlink/apps/towonel/towonel/app/kustomization.yaml`, and
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

`edge.frostlink.dev` must resolve to the VPS itself, and so must every public record. A proxied
record hands the connection to Cloudflare, which cannot carry the Headscale passthrough or reach
the node's public ports the way the front door expects.

external-dns runs **without** `--cloudflare-proxied`, so records are grey by default. On the
**CRD source an annotation on the DNSEndpoint is ignored** — a per-record override has to be
`providerSpecific` on the endpoint (`envoy-gateway/app/dnsendpoint.yaml` shows the shape).

Verify with `dig +short edge.frostlink.dev @1.1.1.1` — a `172.64.x.x` answer means it is proxied.

Artemis removed its `*.frostlink.dev` wildcard on 2026-11-12, so a hostname without its own record
does not resolve. This cluster's external-dns must never be repointed at owner id `artemis` or
prefix `k8s.artemis.%{record_type}-` — see `oci-networking.md` § The `frostlink.dev` zone is shared with
Artemis.

## Ports

Two kinds: ports the DaemonSet declares and holds for its lifetime, and ports the edge binds
**on demand** when an agent registers a TCP/UDP service.

### Static — declared on the DaemonSet

| Port      | Proto | Where            | Open on OCI?                                                   |
| --------- | ----- | ---------------- | -------------------------------------------------------------- |
| 443       | TCP   | edge TLS (SNI)   | open, but **Envoy gets the traffic** (BPF); the edge sees none |
| 51820     | UDP   | iroh QUIC        | **yes** — where agents connect                                 |
| 8443      | TCP   | hub API          | **no** — via Envoy                                             |
| 80        | TCP   | edge HTTP        | open, but **Envoy gets the traffic**; the edge sees none       |
| 51444     | TCP   | hub↔edge link    | no — single pod, disabled                                      |
| 9090/9091 | TCP   | edge/hub metrics | no — scraped in-cluster                                        |

The edge still binds host 443 and 80 (chart values). Moving it off them is parked: the advertised
address would have to change, and that is the risk.

Missing the UDP half fails **silently**: QUIC never establishes and there is no error.

### Dynamic — bound per agent service

The edge binds a port per agent TCP/UDP service while a session exists. Today that is
`15001/tcp` for `artemis-backhaul`. It is **not** open on the OCI security list: only the Frostlink
pod reaches it, in-cluster (`towonel` Service, `home-backhaul`). These listeners are absent from
`kubectl get ds -n towonel towonel -o yaml --context frostlink`. The edge logs them:

```text
edge tcp listener bound   port=15001 service=artemis-backhaul
```

They exist only while the agent session does, so probing the port while the agent is down proves
nothing. The invite must grant the port (`tcp_ports`), or the edge declines to bind with no error.

## Monitoring

The chart ships hub alerts and a ServiceMonitor, which vm-operator converts into `VMRule` /
`VMServiceScrape`. Edge alerts are **not** in the chart — they are lifted from `eleboucher/homelab`
into `app/prometheusrule-edge.yaml` with the upstream `cluster="towonel-ops"` selector dropped
(that exists only because their hub runs outside their cluster).

Leave `TowonelEdgeNoSessions` on: zero sessions is not a valid steady state now that agents exist.
A dead tunnel takes every `dcunha.io` name down behind the `home-down` page, and this alert is the
one that says why. The `for: 10m` tolerates an agent rollout without flapping.

## Operating

```bash
# health
kubectl -n towonel logs ds/towonel --tail=50 --context frostlink
curl -s https://hub.frostlink.dev/v1/readyz            # {"status":"ok"}

# is the hub the active leader (should be 1), and how many agents are attached (should be 1 —
# the Artemis agent; 0 is an outage)
kubectl -n towonel run q --rm -i --restart=Never --context frostlink --image=mirror.gcr.io/curlimages/curl \
  --command -- sh -c '
    curl -s http://towonel.towonel.svc.cluster.local:9091/metrics | grep towonel_hub_is_leader
    curl -s http://towonel.towonel.svc.cluster.local:9090/metrics | grep towonel_edge_active_sessions'

# agent sessions, from the logs
kubectl -n towonel logs ds/towonel --tail=200 --context frostlink | grep 'agent session'

# on-demand backup of the key material
mise run //kube/clusters/frostlink:snapshot-pvc towonel towonel
```

Creating an invite uses the operator API key the node generates into `/data` (`/data/operator.key`;
never print it); the hub API is at `https://hub.frostlink.dev`. Invites are scoped to a hostname
list and returned as a `tt_inv_2_<token>` string:

```bash
towonel invite create --name <agent> --hostnames '<host>,*.<host>'
```

**The invite carries the port grants**, not just the hostnames (`towonel invite create --help` for
the port flags). Artemis's agent claims no hostnames and publishes one TCP service (`artemis-backhaul`, port 15001,
in its `towonel-agent/app/helmrelease.yaml`), so its invite needs `tcp_ports: [15001]`. A service on
the agent side without a matching grant leaves the edge declining to bind the listener, with no
error on either side.

## Gotchas

- **`helm show chart oci://codeberg.org/towonel/charts/towonel` 404s** — the chart is
  `towonel-node` (hub and/or edge). The agent (on Artemis) is plain app-template, not a towonel
  chart.
- **The chart's derived probes use `timeoutSeconds: 1`** — the same too-tight setting
  that let a brief Postgres blip kill the mautrix bridges. They are loosened in the
  HelmRelease; do not let a chart bump quietly reset them.
- **Two startup log lines are harmless.** `edge_link listen_addr and psk must both be set; edge_link
  disabled` (that link only matters for remote edges) and `Insecure TLS config: server certificates
  will be trusted without verification` (`iroh_relay::tls`, the relay client's default, not
  towonel's public TLS path).

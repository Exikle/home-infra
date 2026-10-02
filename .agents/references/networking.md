# Reference: Networking — Frostlink

## Gateway

Frostlink has **one gateway**: `external-gateway` in the `network` namespace. There is no internal-gateway.

- Service type: `ClusterIP` — not directly exposed; all traffic **to this gateway** arrives via
  the Cloudflare tunnel. It is not the only ingress on the host — see _Frostlink is not
  zero-inbound_ below.
- TLS cert: `frostlink-dev-tls` (wildcard, issued in `network` — see _Wildcard cert_ below)
- HTTP listener: `allowedRoutes.namespaces.from: Same` (network namespace only) — handled by the HTTPS redirect HTTPRoute
- HTTPS listener: `allowedRoutes.namespaces.from: All` — all namespaces can attach routes

### Route parentRef

All HTTPRoutes attach to `external-gateway`:

```yaml
parentRefs:
    - name: external-gateway
      namespace: network
```

Routes are defined **inline in helmrelease values** under `route.app:` — not as standalone HTTPRoute files.

## DNS

### external-dns-cloudflare

The app directory is `kubernetes/apps/network/cloudflare-dns/`; the **Deployment is named
`external-dns-cloudflare`** — search for the latter when inspecting the cluster. Live flags,
verified 2026-08-22:

| Flag                              | Value                                               |
| --------------------------------- | --------------------------------------------------- |
| `--source`                        | `crd`, `gateway-httproute`                          |
| `--gateway-name`                  | `external-gateway` (routes on no other gateway)     |
| `--domain-filter`                 | `frostlink.dev`                                     |
| `--policy`                        | `sync` — it **deletes** records it believes it owns |
| `--txt-owner-id` / `--txt-prefix` | `frostlink` / `k8s.%{record_type}-`                 |
| `--cloudflare-proxied`            | set — records default to **orange**                 |

DNS target annotation on the gateway: `external-dns.kubernetes.io/target:
external.frostlink.dev`.

**A `target` annotation on an individual HTTPRoute does not override that.** In the
`gateway-httproute` source the target comes from the _Gateway_, and the per-route annotation is
ignored — verified the hard way on Artemis 2026-08-19, where it published a record pointing at the
wrong tunnel. An earlier revision of this file showed exactly that annotation as the way to
override a route's target; it does not work. If a record needs a different target, put it in a
`DNSEndpoint` and let the `crd` source publish it.

Two records are deliberately **grey**, via `providerSpecific` on the `DNSEndpoint` (an annotation
on the DNSEndpoint object is ignored — it must be `providerSpecific` on the endpoint itself):

| Record               | Owner        | Why grey                                      |
| -------------------- | ------------ | --------------------------------------------- |
| `edge.frostlink.dev` | this cluster | SNI routing needs the connection, not the CDN |
| `*.frostlink.dev`    | **Artemis**  | wildcard CNAME to the edge, for towonel       |

### The `frostlink.dev` zone is shared with Artemis

Artemis runs a second external-dns (`external-dns-frostlink`) against this same zone, also with
`policy: sync`. The two do not fight because they differ in **both** owner id and TXT prefix:

| Instance                            | `txt-owner-id` | `txt-prefix`                  |
| ----------------------------------- | -------------- | ----------------------------- |
| frostlink `external-dns-cloudflare` | `frostlink`    | `k8s.%{record_type}-`         |
| Artemis `external-dns-frostlink`    | `artemis`      | `k8s.artemis.%{record_type}-` |

Matching prefixes with different owner ids is the loop — they overwrite each other's registry TXT
records and then delete each other's entries. **Do not change either value on this side.**
Artemis's `towonel-agent.md` § The collision guard is the authority.

Because Artemis owns a grey `*.frostlink.dev` wildcard, a **new app on this cluster needs its own
explicit record** — otherwise the hostname falls through the wildcard to Artemis's edge. Any
HTTPRoute on `external-gateway` gets one automatically; a manual `DNSEndpoint` does not unless you
write it.

### Wildcard cert

`*.frostlink.dev` wildcard cert issued by cert-manager via Cloudflare DNS-01. The `Certificate`
(`frostlink-dev`) lives in `network`, next to the gateway, and writes the secret
`frostlink-dev-tls` there. A PushSecret backs that secret up to the 1Password item
`frostlink-dev-tls`; on a rebuild the `certificates-import` ExternalSecret (`CreatedOnce`,
`Orphan`) restores it from 1Password before `certificates-export` runs, so cert-manager adopts the
existing cert instead of requesting a new one. Manifests: `kubernetes/apps/network/certificates/`.

## CoreDNS suppresses AAAA — the cluster is IPv4-only

`cilium-config` has `enable-ipv6=false` and the node has a single IPv4 podCIDR
(`10.244.0.0/24`); the node itself has no global IPv6 address. Pods therefore get a link-local
`fe80::` on eth0 and nothing routable.

CoreDNS forwards to `169.254.169.254`, which happily returns **AAAA** records for external names.
A pod that dials one gets `connect: network is unreachable` instantly. Because the `loadbalance`
plugin shuffles record order per response, this is a per-response dice roll rather than a
deterministic failure — it bit roughly 6% of Kopiur backups to Cloudflare R2, which surfaced as
`kopiaErrorClass: RepositoryUnavailable` /
`dial tcp [2606:4700:113::1]:443: connect: network is unreachable` and looked for a long time like
a credential or repository fault. It is neither.

The `template IN AAAA` plugin with `rcode NOERROR` returns NODATA for every AAAA query, so no pod
is ever handed an address it cannot reach. On an IPv4-only cluster this costs nothing — there is
no client that could have used the answer.

Two caveats worth keeping:

- The `template` plugin runs **before** `kubernetes` in CoreDNS's fixed plugin chain (plugin
  ordering comes from `plugin.cfg`, not from the order in the Corefile), so it also answers AAAA
  for `cluster.local`. That is correct here — those services are IPv4-only too — but it means the
  block is genuinely cluster-wide, not just external. Scope it with a zone argument
  (`template IN AAAA cloudflarestorage.com`) if that ever becomes undesirable.
- **Unexplained**: Go's dialer implements Happy Eyeballs and should fall back to IPv4 when the
  AAAA dial returns `ENETUNREACH` immediately, yet kopia did not. Suppressing AAAA removes the
  failure path regardless, so the fix stands on its own, but the underlying mechanism was never
  pinned down. If AAAA suppression is ever reverted, expect the failures to return.

## cilium `rollOutCiliumPods` is false

Set to `false` to match Artemis. With `true`, every cilium Helm reconcile restarts the agent, and
during the restart the socketLB BPF service map is briefly empty — pod connects to a ClusterIP
then fail with `EPERM` (`connect: operation not permitted`) rather than a refusal or timeout. On a
single node there is nowhere to shift traffic while that happens, so the restart is a cluster-wide
blip for no benefit. Rolling the agent on a values change is a convenience, not a requirement;
restart it deliberately when a cilium change actually needs it.

Read `EPERM` on a ClusterIP dial as "socketLB found zero backends", not as a NetworkPolicy denial.

## cilium `devices` and `MTU` are pinned

`devices: enp0s6` and `MTU: 1500` in the Cilium HelmRelease. Without them, device auto-detection
picks up `tailscale0` too, and Cilium sizes every pod interface to the **smallest** detected
device — tailscale's 1280 — while `enp0s6` runs at 9000. Pinned since 2026-10-02.

- **Why 1500, not 9000:** 1500 is the internet path MTU out of the OCI VCN, so pod egress never
  depends on path-MTU discovery. Nothing on this single node needs jumbo frames between pods.
- **Dropping `tailscale0` is safe** because no pod traffic routes over it — the node only carries
  routes to individual tailnet peers, and no manifest addresses a tailnet or Artemis-LAN IP. If a
  pod ever needs to reach the tailnet, add the device back (`devices: enp0s6,tailscale0`) **and**
  keep `MTU` pinned, or the 1280 floor returns.
- **An MTU change only reaches existing pods when they are recreated.** The agent restart
  (needed here because `rollOutCiliumPods` is false) moves the host-side `lxc*` interfaces, but
  each pod's own `eth0` keeps its old MTU until the pod is replaced. Check with
  `kubectl exec <pod> -- cat /sys/class/net/eth0/mtu`.

## cilium cluster identity: `id: 2`, `name: frostlink-vps`

Artemis is `id: 1`; ClusterMesh needs every cluster's ID and name unique. Changed 2026-10-02 from
`id: 1` / `frostlink`.

- **Change the ID and the name together, never the ID alone.** The name is a pod identity label
  (`io.cilium.k8s.policy.cluster`); the ID is not. With an ID-only change the existing identities
  keep matching and Cilium reuses them, old numbers and all — restarting workloads does not help
  (Cilium maintainer, cilium/cilium#48801). Changing the name forces new identities.
- **No reboot.** Apply the values, then restart `deploy/cilium-operator` and `ds/cilium` by hand
  (`rollOutCiliumPods` is false). Every endpoint re-identifies on the agent restart; old
  identities are garbage-collected on their own.
- Verify the range: cluster N identities are `N*65536 … N*65536+65535`, so cluster 2 is
  `131072–196607`. `cilium-dbg endpoint list -o json` shows each endpoint's `identity.id`.
- **Not supported once meshed** — changing ID or name on a cluster that is already connected
  needs every peer disconnected first.

## Cloudflare Tunnel

The tunnel sends `frostlink.dev` and `*.frostlink.dev` traffic to the `external-gateway` service in
the `network` namespace. It carries **most** ingress, and everything this cluster serves itself.

## Frostlink is not zero-inbound — the edge listens directly

This changed when towonel landed (2026-08-18) and it is the first thing to correct in any older
mental model of this host. Two ports are open on the OCI security list and bound on the node:

| Port        | Bound by                      | What breaks if it is closed                              |
| ----------- | ----------------------------- | -------------------------------------------------------- |
| `443/tcp`   | towonel edge (hostNetwork DS) | every tunnelled origin — SNI routing has nowhere to land |
| `51820/udp` | towonel edge, iroh QUIC       | agents fall back to relay or never connect, **silently** |

Consequences that are easy to get wrong:

- **The towonel edge owns host `:443`, not Envoy.** `external-gateway` is `ClusterIP` and is only
  ever reached through cloudflared. The two paths do not share a listener.
- **Traffic for an Artemis-published `*.frostlink.dev` name never enters this cluster's Envoy.**
  The edge peeks at SNI and forwards the raw TLS stream to the Artemis agent; nothing here
  terminates it. See `towonel.md`.
- The edge also binds **per-service TCP/UDP ports on demand** while an agent session exists —
  currently `25565/tcp` (minecraft) and `3000/udp` (eco), both Artemis origins. Those are
  additional public listeners on this host. `towonel.md` § Ports carries the full table.

## Cluster-Internal Traffic

Always use `svc.cluster.local` — never external hostnames:

```text
<app>.<namespace>.svc.cluster.local
```

## Oracle Cloud VCN

Verified against the console 2026-08-18. The earlier version of this section was
wrong in both directions — 80/443 were **not** open, and 50000/6443 were **not**
scoped to a home IP.

- **Security list ingress** (all stateful, all `0.0.0.0/0` unless noted):
    - `443/tcp` — towonel edge, TLS with SNI routing
    - `51820/udp` — towonel iroh QUIC. **Missing the UDP half fails silently.**
    - `50000/tcp` — Talos API. `talosconfig` points at the **public** IP, not
      Tailscale, so closing this locks out `talosctl` until that is repointed.
    - `22/tcp` — dead weight; Talos runs no SSH daemon
    - `icmp` 3,4 (path MTU) and `icmp` 3 from `10.0.0.0/16`
    - `25565/tcp` and `3000/udp` — towonel per-service listeners for Artemis's
      minecraft and eco. Not in the 2026-08-18 console reading, but demonstrably
      reachable: on 2026-08-22 the edge logged unsolicited public peers arriving on
      `tcp:minecraft` from several unrelated internet addresses. **Re-read the console
      and record the actual rule** — the list above is otherwise console-verified and
      this entry is inferred.
- **Deliberately closed**:
    - `8443/tcp` — the towonel hub API is bound on the host but speaks plain HTTP.
      It is reached through cloudflared at `hub.frostlink.dev` instead. Opening this
      exposes the operator API in cleartext.
    - `80/tcp` — the towonel edge binds it, but origins use DNS-01, not HTTP-01.
    - `6443/tcp` — removed 2026-08-18. `kubeconfig` uses the Tailscale address, so
      the Kubernetes API never needed to be public.
- **Security list egress**: all allowed — this is what carries Tailscale, which is
  outbound-initiated and has no ingress rule of its own.

Stateless rules would break this: OCI skips connection tracking for any flow that
matches one, and a stateless rule takes precedence over a stateful one.

## Access Methods

| Access type       | Method                                 | Address                                     |
| ----------------- | -------------------------------------- | ------------------------------------------- |
| Kubernetes API    | Tailscale                              | `100.67.108.103:6443`                       |
| Talos API         | **Public IP** (`talosconfig` endpoint) | `40.233.88.33:50000`                        |
| App traffic       | Cloudflare tunnel → external-gateway   | `*.frostlink.dev`                           |
| Tunnelled origins | towonel edge, direct to the VPS        | `edge.frostlink.dev:443`                    |
| Tunnelled TCP/UDP | towonel edge, per-service port         | `edge.frostlink.dev:25565/tcp`, `:3000/udp` |
| towonel hub API   | Cloudflare tunnel → external-gateway   | `hub.frostlink.dev`                         |
| Node debug        | Tailscale → talosctl                   | `100.67.108.103`                            |

## kubectl context

`kubernetes/mod.just` hardcodes `kubectl --context frostlink` — all `just kube` commands target Frostlink automatically. Bare `kubectl` commands need `--context frostlink` or `kubectx frostlink` first.

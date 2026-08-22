# Reference: Networking — Frostlink

## Gateway

Frostlink has **one gateway**: `external-gateway` in the `network` namespace. There is no internal-gateway.

- Service type: `ClusterIP` — not directly exposed; all traffic **to this gateway** arrives via
  the Cloudflare tunnel. It is not the only ingress on the host — see _Frostlink is not
  zero-inbound_ below.
- TLS cert: `frostlink-dev-tls` (wildcard, exported into `network` namespace via PushSecret)
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

| Flag                                  | Value                                              |
| ------------------------------------- | -------------------------------------------------- |
| `--source`                            | `crd`, `gateway-httproute`                         |
| `--gateway-name`                      | `external-gateway` (routes on no other gateway)    |
| `--domain-filter`                     | `frostlink.dev`                                    |
| `--policy`                            | `sync` — it **deletes** records it believes it owns |
| `--txt-owner-id` / `--txt-prefix`     | `frostlink` / `k8s.%{record_type}-`                |
| `--cloudflare-proxied`                | set — records default to **orange**                |

DNS target annotation on the gateway: `external-dns.alpha.kubernetes.io/target:
external.frostlink.dev`.

**A `target` annotation on an individual HTTPRoute does not override that.** In the
`gateway-httproute` source the target comes from the *Gateway*, and the per-route annotation is
ignored — verified the hard way on Artemis 2026-08-19, where it published a record pointing at the
wrong tunnel. An earlier revision of this file showed exactly that annotation as the way to
override a route's target; it does not work. If a record needs a different target, put it in a
`DNSEndpoint` and let the `crd` source publish it.

Two records are deliberately **grey**, via `providerSpecific` on the `DNSEndpoint` (an annotation
on the DNSEndpoint object is ignored — it must be `providerSpecific` on the endpoint itself):

| Record                | Owner              | Why grey                                     |
| --------------------- | ------------------ | -------------------------------------------- |
| `edge.frostlink.dev`  | this cluster       | SNI routing needs the connection, not the CDN |
| `*.frostlink.dev`     | **Artemis**        | wildcard CNAME to the edge, for towonel       |

### The `frostlink.dev` zone is shared with Artemis

Artemis runs a second external-dns (`external-dns-frostlink`) against this same zone, also with
`policy: sync`. The two do not fight because they differ in **both** owner id and TXT prefix:

| Instance                             | `txt-owner-id` | `txt-prefix`                  |
| ------------------------------------ | -------------- | ----------------------------- |
| frostlink `external-dns-cloudflare`  | `frostlink`    | `k8s.%{record_type}-`         |
| Artemis `external-dns-frostlink`     | `artemis`      | `k8s.artemis.%{record_type}-` |

Matching prefixes with different owner ids is the loop — they overwrite each other's registry TXT
records and then delete each other's entries. **Do not change either value on this side.**
Artemis's `towonel-agent.md` § The collision guard is the authority.

Because Artemis owns a grey `*.frostlink.dev` wildcard, a **new app on this cluster needs its own
explicit record** — otherwise the hostname falls through the wildcard to Artemis's edge. Any
HTTPRoute on `external-gateway` gets one automatically; a manual `DNSEndpoint` does not unless you
write it.

### Wildcard cert

`*.frostlink.dev` wildcard cert issued by cert-manager via Cloudflare DNS-01. Stored as `frostlink-dev-tls` in `cert-manager`, exported to the `network` namespace via PushSecret so the gateway can use it.

## Cloudflare Tunnel

The tunnel sends `frostlink.dev` and `*.frostlink.dev` traffic to the `external-gateway` service in
the `network` namespace. It carries **most** ingress, and everything this cluster serves itself.

## Frostlink is not zero-inbound — the edge listens directly

This changed when towonel landed (2026-08-18) and it is the first thing to correct in any older
mental model of this host. Two ports are open on the OCI security list and bound on the node:

| Port        | Bound by                       | What breaks if it is closed                                |
| ----------- | ------------------------------ | ---------------------------------------------------------- |
| `443/tcp`   | towonel edge (hostNetwork DS)  | every tunnelled origin — SNI routing has nowhere to land    |
| `51820/udp` | towonel edge, iroh QUIC        | agents fall back to relay or never connect, **silently**    |

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

| Access type    | Method                             | Address                   |
| -------------- | ---------------------------------- | ------------------------- |
| Kubernetes API | Tailscale                          | `100.67.108.103:6443`     |
| Talos API      | **Public IP** (`talosconfig` endpoint) | `40.233.88.33:50000`  |
| App traffic    | Cloudflare tunnel → external-gateway | `*.frostlink.dev`       |
| Tunnelled origins | towonel edge, direct to the VPS  | `edge.frostlink.dev:443`  |
| Tunnelled TCP/UDP | towonel edge, per-service port   | `edge.frostlink.dev:25565/tcp`, `:3000/udp` |
| towonel hub API | Cloudflare tunnel → external-gateway | `hub.frostlink.dev`     |
| Node debug     | Tailscale → talosctl               | `100.67.108.103`          |

## kubectl context

`kubernetes/mod.just` hardcodes `kubectl --context frostlink` — all `just kube` commands target Frostlink automatically. Bare `kubectl` commands need `--context frostlink` or `kubectx frostlink` first.

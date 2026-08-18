# Reference: Networking — Frostlink

## Gateway

Frostlink has **one gateway**: `external-gateway` in the `network` namespace. There is no internal-gateway.

- Service type: `ClusterIP` — not directly exposed; all traffic arrives via Cloudflare tunnel
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

`cloudflare-dns` in the `network` namespace runs external-dns pointed at Cloudflare. It watches:
- `gateway-httproute` — creates DNS records for every HTTPRoute attached to `external-gateway`
- `crd` — `DNSEndpoint` objects for manual entries

All DNS records are Cloudflare-proxied. DNS target annotation on the gateway: `external-dns.alpha.kubernetes.io/target: external.frostlink.dev`

```yaml
# To override the DNS target for a specific route, annotate the HTTPRoute:
annotations:
    external-dns.alpha.kubernetes.io/target: external.frostlink.dev
```

### Wildcard cert

`*.frostlink.dev` wildcard cert issued by cert-manager via Cloudflare DNS-01. Stored as `frostlink-dev-tls` in `cert-manager`, exported to the `network` namespace via PushSecret so the gateway can use it.

## Cloudflare Tunnel

The tunnel sends `frostlink.dev` and `*.frostlink.dev` traffic to the envoy gateway service in the `network` namespace. No port 80/443 are directly exposed on the OCI instance — the tunnel is the only ingress path.

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
| towonel hub API | Cloudflare tunnel → external-gateway | `hub.frostlink.dev`     |
| Node debug     | Tailscale → talosctl               | `100.67.108.103`          |

## kubectl context

`kubernetes/mod.just` hardcodes `kubectl --context frostlink` — all `just kube` commands target Frostlink automatically. Bare `kubectl` commands need `--context frostlink` or `kubectx frostlink` first.

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

- **Security list ingress**:
    - `50000/tcp` + `6443/tcp` — from home IP only (Talos API + Kubernetes API)
    - `80/tcp` + `443/tcp` — from `0.0.0.0/0` (future direct access, currently unused by tunnel)
- **Security list egress**: all allowed

## Access Methods

| Access type    | Method                             | Address                   |
| -------------- | ---------------------------------- | ------------------------- |
| Kubernetes API | Tailscale                          | `100.67.108.103:6443`     |
| Talos API      | Tailscale                          | `100.67.108.103:50000`    |
| App traffic    | Cloudflare tunnel → external-gateway | `*.frostlink.dev`       |
| Node debug     | Tailscale → talosctl               | `100.67.108.103`          |

## kubectl context

`kubernetes/mod.just` hardcodes `kubectl --context frostlink` — all `just kube` commands target Frostlink automatically. Bare `kubectl` commands need `--context frostlink` or `kubectx frostlink` first.

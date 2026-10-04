# ClusterMesh — Frostlink ⇄ Artemis

Cilium ClusterMesh joins Frostlink (`frostlink-vps`, id 2) and Artemis (`artemis-cluster`, id 1)
over the Headscale site link. Live since 2026-10-03. It gives **global services**: the same
Service name and namespace in both clusters, with backends from either. This file is canonical
for both repos; Artemis's `networking.md` § ClusterMesh holds only its side's specifics.

Health: `kubectl -n kube-system exec deploy/clustermesh-apiserver -c kvstoremesh -- clustermesh-apiserver kvstoremesh-dbg status`
on either cluster — `1/1 remote clusters ready`. `cilium-dbg status | grep ClusterMesh` on any agent.

## How traffic crosses

Both clusters run **native routing** (mixed native/tunnel is unsupported). Pod IPs cross the
tailnet unmasqueraded in both directions:

| Hop                                      | Mechanism                                                                                                                |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Artemis pod ranges `10.42.x.0/24` → UCG  | Artemis BGP advertises `PodCIDR` (`kube-system/cilium/app/network.yaml`)                                                 |
| UCG → tailnet                            | the UCG advertises `10.42.0.0/16` (`ucg_tailscale` role); Headscale auto-approves it                                     |
| Frostlink pods `10.244.0.0/24` → tailnet | Frostlink's tailscale advertises it (`talos/patches/tailscale.yaml.j2`)                                                  |
| Frostlink pod → Artemis pod              | BPF FIB lookup honours tailscale's policy table 52 → `tailscale0`; `tailscale0` is not a Cilium device, so no masquerade |
| Artemis pod → LAN hosts                  | still masqueraded to the node IP: ip-masq-agent exempts only the two pod ranges                                          |

**Access is in `kubernetes/apps/network/headscale/app/resources/policy.hujson`.** The mesh needs
pod ↔ pod both ways, Frostlink node → Artemis `:2379`/`:4240`, and **Artemis pods → Frostlink
node `10.0.0.203` on `:12379`/`:4240`**. That last one is easy to miss: once meshed, each cluster
knows the other's node IPs as cluster nodes and Cilium stops masquerading pod traffic to them, so
it arrives from `10.42.x`, not a LAN node IP. Without the grant the mesh connects once and then
fails on reconnect with `timed out while starting the heartbeat watcher`.

## The two mesh endpoints

KVStoreMesh is on (chart default): each agent talks to its own cluster's
`clustermesh-apiserver`, and that pod's `kvstoremesh` container dials the other cluster.

| Cluster   | Endpoint the peer dials                                                    | Why                                                            |
| --------- | -------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Artemis   | LoadBalancer `10.10.99.93:2379`, BGP-advertised, `forwarding-mode: snat`   | ordinary LB IP, reachable from Frostlink pods over the tailnet |
| Frostlink | `10.0.0.203:12379` → `cilium/relay` → service `clustermesh-apiserver:2379` | see below                                                      |

**Why a relay:** Cilium only handles NodePorts on its devices (`enp0s6`); traffic from home
arrives on `tailscale0`, so a NodePort answers "connection refused" over the tailnet. The relay is
a hostNetwork haproxy (TCP passthrough, TLS stays end-to-end). Making `tailscale0` a Cilium device
was rejected: it would put BPF masquerade on the tailnet path and hits an open tcx bug on it.

Peers are declared once, identically in both HelmReleases (`clustermesh.config.clusters`, keys =
cluster names, `ips` override). With `ips` set the endpoint becomes
`https://<name>.mesh.cilium.io:<port>`, which matches the chart's built-in `*.mesh.cilium.io` SAN
— no extra cert SANs. `cacheTTL: 15m` drops a dead peer's backends.

## Shared CA

One CA for both clusters in 1Password `infrastructure/cilium-clustermesh-ca` (both Connect
instances read `infrastructure`). An ExternalSecret `cilium-clustermesh-ca` in `kube-system`
re-encodes it base64 (the chart's `buildCustomCert` wants base64 PEM), and the Cilium HelmRelease
feeds it in via `valuesFrom` → `tls.ca.cert` / `tls.ca.key`. The chart (`method: helm`) then
renders `cilium-ca` and every mesh cert from it. Pattern from neilmfrench/homelab-prod; none of
onedr0p/bjw-s/buroa run ClusterMesh.

- The helmfile bootstrap reads only `spec.values`, so a rebuild starts with a throwaway CA and
  the first Flux reconcile replaces it.
- Leaf certs renew only on a Helm upgrade (365-day validity) — any values change does it.
- **Rotate:** generate a new RSA CA (`openssl genrsa -traditional`), replace the 1P item, force-sync
  the ExternalSecret on both clusters, reconcile both Cilium HelmReleases, restart
  `deploy/clustermesh-apiserver` and `ds/cilium` on both. The mesh is down between the two sides.

## Global services

```yaml
metadata:
    annotations:
        service.cilium.io/global: "true"
        service.cilium.io/affinity: local # failover: local backends first
        service.cilium.io/forwarding-mode: snat # Artemis, externally exposed services only
```

Same name and namespace in both clusters. **Artemis uses DSR**, and DSR to a remote backend
breaks (the reply leaves Oracle's default route), so an externally reachable global service on
Artemis needs `forwarding-mode: snat` (`bpf.lbModeAnnotation` is on). Pod → ClusterIP is fine.
`policyDefaultLocalCluster` is on: a NetworkPolicy matches only local pods unless it names a
cluster.

Proven 2026-10-03 with a throwaway echo service: 10/10 to Artemis, Artemis copy deleted → 10/10
to Frostlink, back → 10/10 Artemis.

## Traps hit building it

- **MTU stays 1500 on Frostlink.** Cross-site TCP is covered by the UCG MSS clamp; large UDP from
  a Frostlink pod to home can still drop silently. Changing Cilium's `MTU` on a live cluster moves
  the host devices at once but not existing pods — on 2026-10-03 a 1500→1280 change stalled every
  public Frostlink site on large responses for ~7 minutes until reverted.
- **`just kube apply-ks` cannot render a HelmRelease whose `valuesFrom` reads a Secret** (flate
  feeds a placeholder; `buildCustomCert: unable to decode base64 certificate`). Flux itself is
  fine. To test-apply by hand: `kustomize build <dir> | kubectl -n kube-system apply --server-side --force-conflicts --field-manager=kustomize-controller -f -`.
- **Never drop the `-n`.** The Cilium app's `kustomization.yaml` has no `namespace:`; without
  `-n kube-system` everything lands in `default`, a second Cilium Helm release installs there and
  takes over Cilium's ClusterRoleBindings (Artemis, 2026-10-03). Recovery: suspend the stray HR,
  repoint the bindings, remove its finalizer and delete it — never `helm uninstall`, which deletes
  the shared cluster-scoped objects.
- **app-template `configMaps` trims the trailing newline**, which haproxy rejects; the relay
  config is a configMapGenerator file. haproxy also needs `maxconn` or it OOMs at 64Mi.

# Reference: Networking — home-infra

## Gateways

| Gateway            | Namespace | LB IP         | Hostnames                                     | Reach                                 | Use for                |
| ------------------ | --------- | ------------- | --------------------------------------------- | ------------------------------------- | ---------------------- |
| `internal-gateway` | `network` | `10.10.99.98` | `*.dcunha.io`                                 | LAN only (UCG-Max DNS)                | Internal-only services |
| `edge-gateway`     | `network` | `10.10.99.90` | `*.frostlink.dev`, `*.dcunha.io`, `dcunha.io` | Public via towonel on frostlink + LAN | Every public service   |
| `external-gateway` | `network` | `10.10.99.97` | `*.dcunha.io`                                 | Nothing upstream                      | Nothing. No new routes |

All three gateways are in `kube/clusters/artemis/apps/network/envoy-gateway/app/envoy.yaml`.
`external-gateway` was the Cloudflare-tunnel path. The team retired the tunnel (`06a0fe138`) after
every public `*.dcunha.io` app moved to `edge-gateway`. The gateway still exists. It carries only
the shared `https-redirect`.

Details of `edge-gateway`:

- It is a LoadBalancer on `10.10.99.90` with the LAN name `edge.dcunha.io`. `towonel-agent` dials
  `edge-gateway.network.svc.cluster.local:443`. LAN clients connect to the IP.
- It has three `:443` listeners: `https` (`frostlink-dev-tls`), `https-dcunha` (`*.dcunha.io`) and
  `https-dcunha-apex` (`dcunha.io`). The last two use `dcunha-io-tls`. The listener table and the
  `sectionName: https` trap are in `towonel-agent.md` § Which gateway a route uses.
- Artemis has no CrowdSec. The Envoy on frostlink terminates TLS for public traffic, and CrowdSec
  on frostlink checks it before it reaches the backhaul (`crowdsec.md`). Nothing checks
  LAN traffic.
- The `:80` listener `http` carries only the shared `https-redirect` route (301 to `https://`, path
  and query kept). LAN clients connect to `10.10.99.90:80`. The Envoy on frostlink redirects public
  `http://`, so it never reaches Artemis. `https-redirect` carries
  `edge-dns.kubernetes.io/controller: none`, so edge-dns ignores it.
- The rate limit for each client is on its own `BackendTrafficPolicy/edge`. It uses the local
  limiter of Envoy. The limit counts per client IP, per route and per Envoy pod. The client IP is
  `sourceCIDR` `Distinct`: the `X-Forwarded-For` client that the Envoy on frostlink sets.
  `ClientTrafficPolicy/edge` trusts that header only from the CIDR of the agent pod. There are 2
  replicas, so the real ceiling is about double the configured number.
- The limit has two rules. One is POSTs to known login paths (one regex). The other is a general
  cap for each IP. There is no Redis/Dragonfly and no rate-limit service, so nothing extra can
  fail. The limit is a separate policy and not part of `BackendTrafficPolicy/envoy`, because two
  gateway-level policies on one Gateway conflict. `envoy` now names `external-gateway` and
  `internal-gateway` explicitly, so the limit never applies to LAN-only apps. Route-level policies
  with `mergeType: StrategicMerge` (immich) inherit the limits.
- There is no PROXY protocol. The backhaul is a towonel TCP service (`artemis-backhaul`, edge port
  15001). It carries the re-encrypted HTTPS from the Envoy on frostlink to `edge-gateway:443`. The
  real client IP is in `X-Forwarded-For`. `ClientTrafficPolicy/edge` trusts it only from
  `10.42.0.0/16` (the agent pod). LAN clients send no XFF, so the gateway uses their own address.
- Raw TCP goes through a ListenerSet. `spec.allowedListeners` admits the `external-endpoints`
  namespace. This is how Forgejo SSH gets port 22 (§ Raw TCP ports on a shared gateway).
- The one towonel TCP service, `artemis-backhaul`, targets this gateway. Any other TCP or UDP
  service goes from the agent straight to the app Service (`towonel-agent.md` § Other TCP and UDP
  services).

Public or LAN decides the gateway. A public service (either domain) uses `edge-gateway`. A LAN-only
service uses `internal-gateway`. An app can carry two routes for two hostnames. For example,
`media/silo` has a `route.app` (`silo.dcunha.io`) and a `route.jellyfin` (`jellyfin.dcunha.io` +
`silo-jf.dcunha.io`, a different port). Both are on `edge-gateway`. The towonel origin mapping is in
`.agents/references/towonel-agent.md`. That file wins over this file on anything about towonel.

Routes go inline under `route.app:`. `cluster-conventions.md` wins on that rule. The exceptions
are in `app-structure.md` § Non-standard resource types.

### Gateway selection rules

One route attaches to exactly one gateway. Pick the gateway by exposure. For a public route, use:

```yaml
parentRefs:
    - name: edge-gateway # reachable from the internet via towonel on frostlink
      namespace: network
```

For a LAN-only route, use:

```yaml
parentRefs:
    - name: internal-gateway
      namespace: network
```

This rule applies to `external-endpoints` services (LXC, Proxmox, TrueNAS, Forgejo) exactly as it
applies to apps that run in Kubernetes. There is no "use both" case. The rule itself is in
`instructions/cluster-conventions.md` (Common Mistakes, route gateway attachment), which wins. The
reason for it is here.

Never attach one route to both gateways. It is not a safety net. It is a silent failure:

- `external-dns-unifi` gets two CNAME targets and keeps one. It logs `ignoring additional
  CNAME targets; only the first target will be used`. The order of `parentRefs` does not decide
  which target stays. `seerr` and `grafana` both listed `internal-gateway` first, and both still
  resolved to `external.dcunha.io`.
- It never settles. external-dns finds the dropped target again on every 60s loop and rewrites the
  UniFi zone each time, with no end.
- The second parentRef gives nothing anyway. The LAN already resolves the gateway of a public route
  (next paragraph).

A route that is only external still gets a LAN record. `external-dns-unifi` has no
`--gateway-name` filter. So it writes a CNAME for every route that it sees, and points it at the
target of the gateway of that route. From the LAN, a public route on `edge-gateway` resolves to
`edge.dcunha.io` → `10.10.99.90`. Traffic goes to the gateway directly and never hairpins out
through the VPS. So services outside Kubernetes do not need a second gateway for LAN clients.

Two routes for one app are correct only for different hostnames (the jellyfin example above).
Never use one route with two parents.

The one correct route with two parents in the tree is `https-redirect` in
`kube/clusters/artemis/apps/network/envoy-gateway/app/envoy.yaml`. It attaches to the `http`
listener of all three gateways (`edge-gateway`, `external-gateway`, `internal-gateway`). It carries
no hostnames, so it makes no DNS record.

### Raw TCP ports on a shared gateway — ListenerSets

To put a port that is not HTTP on an existing gateway, use a Gateway API `ListenerSet` (v1) and a
`TCPRoute`/`UDPRoute`. Do not use a dedicated LoadBalancer IP. The gateway must opt in with
`spec.allowedListeners`. `edge-gateway` and `external-gateway` both allow ListenerSets only from the
`external-endpoints` namespace. Envoy Gateway then adds the port to the Service of the gateway.

The live example is Forgejo SSH. `external-endpoints/forgejo-ssh` is a ListenerSet with a TCP `ssh`
listener on 22. It has a `TCPRoute` to a headless `forgejo-ssh` Service, and an EndpointSlice that
points at the LXC (`10.10.99.24:22`). Its parent is `edge-gateway`. So `git.dcunha.io` answers HTTPS
and SSH on `.90`, and the `SSH_DOMAIN` of Forgejo is `git.dcunha.io`.

By decision, SSH stays on the LAN and Headscale only. towonel routes TLS by SNI, so SSH needs a
public TCP port on the VPS. The team considered that and rejected it because of scanner noise and
the port mismatch. Route `parentRefs` use `group: gateway.networking.k8s.io` and
`kind: ListenerSet`. Do not use the old `gateway.networking.x-k8s.io` group. Its `xlistenersets`
CRD is a leftover.

### Do not rename `compression` to `compressor` on Envoy Gateway 1.9.x

The CRD marks `BackendTrafficPolicy.spec.compression` as _"Deprecated: Use Compressor instead"_.
The policy carries a `DeprecatedField` warning on every gateway. On 1.9.x, do not act on it. The CRD
accepts `spec.compressor` and the status goes `Accepted=True`, so the change looks like a clean
fix. But on 1.9.0 the controller did not translate the field, and all compression stopped with no
error. The CRD schema and the behaviour of the controller do not change together. Make sure of the
result with the live filter chain, not with the policy status:

```bash
kubectl port-forward -n network <edge-gateway-or-internal-gateway-pod> 19000:19000
curl -s localhost:19000/config_dump |   jq -r '.configs[].dynamic_listeners[]?.active_state.listener.filter_chains[]?.filters[]?
         .typed_config.http_filters[]?.name' | sort -u
```

On 1.9.1, compression no longer stops. But `compressor` loses zstd and ignores list order.
`Accept-Encoding: zstd` alone gets nothing, and `zstd, br, gzip` gets `br`. Test with
`curl -s -o /dev/null -D - -H "Accept-Encoding: zstd" https://<app>` against each gateway IP.
Artemis now runs a later minor
(`grep tag: kube/clusters/artemis/apps/network/envoy-gateway/app/ocirepository.yaml`). No re-test
on it is recorded. Until someone tests it with the commands above, keep `compression`. The
deprecation warning is the smaller problem.

### Proxies roll all at once (`maxSurge: 100%`)

Both `EnvoyProxy` objects set `strategy.rollingUpdate` to `maxSurge: 100%, maxUnavailable: 0`. So
every proxy pod of a gateway is replaced in one step. The old pods leave as soon as the new pods are
Ready. Proxies that still run when a new controller starts can lose their TLS certificates about 15
seconds later, while they still report Ready (EG v1.9.1 release notes). A rollout of one pod at a
time makes that window longer. The cluster has room for double the proxies.

The controller rolls the proxies itself about 20 seconds after it starts. The shutdown-manager
sidecar uses the controller image. So a manual `rollout restart` of the gateways only creates an
extra second generation. The real length of the window with mixed versions is the first pull of a
new Envoy image (~55s per node).

### `envoy.enabled: false` does not disable Envoy

This Cilium Helm value picks between Envoy embedded in the agent and a standalone DaemonSet. It does
not turn Envoy on or off. With our `envoy.enabled: false`, `cilium-dbg status` reports
`Envoy: embedded`, and the L7 proxy runs. It has 0 active redirects, because no L7
CiliumNetworkPolicies or CiliumEnvoyConfigs exist for it to serve. The chart default is `true`. So
we opt out of the DaemonSet, not out of Envoy. The cost of the embedded mode is that an agent
restart disrupts live traffic through the L7 proxy, and Envoy shares the resource limits of the
agent. With no redirects, that costs nothing today.

This has no relation to `network/envoy-gateway`. Cilium knows nothing about it.

## Cluster-Internal Traffic

Pod-to-pod traffic uses `<app>.<namespace>.svc.cluster.local` or `<app>.<namespace>.svc`, never
an external hostname. `AGENTS.md` rule 5 is the home for that rule, and it wins.

## VLANs

| VLAN | Name | Subnet          | IPv6                    | Purpose                                                    |
| ---- | ---- | --------------- | ----------------------- | ---------------------------------------------------------- |
| 1001 | HME  | 10.10.1.0/24    | none                    | Trusted home                                               |
| 1099 | LAB  | 10.10.99.0/24   | `2607:fea8:4e1f:3800::` | Servers, K8s nodes                                         |
| 1152 | IOT  | 10.10.152.0/24  | `2607:fea8:4e1f:3801::` | IoT (reachable from worker pods)                           |
| 1062 | CAM  | 10.10.62.0/24   | none                    | Cameras, reached by frigate through the `cam` NAD          |
| 1151 | GST  | 10.10.151.0/24  | none                    | Guest                                                      |
| 1088 | TST  | 192.168.88.0/24 | none                    | Testing                                                    |
| 1    | LAN  | 192.168.1.0/24  | none                    | Native/untagged on the UCG and CRS309 uplinks and pantheon |

Not a VLAN: the WireGuard server `10.10.2.0/24` on the UCG. Wi-Fi:
`SGxAP` → HME, `SGxGuest` → GST, `SGxIoT` → IOT.

DNS: the UCG-Max at 10.10.99.1 serves LAN DNS. It answers the `*.dcunha.io` names that
external-dns-unifi writes into it, and it forwards everything else. It is not authoritative for the
zone. It also does WAN/NAT, VLANs, DHCP and BGP (AS 64533). The IPs of the nodes, atlas and pantheon
are DHCP reservations, not static addresses. The UCG overrides only the A record. See § CoreDNS,
Guard 2.

The LAN-side AAAA leak works like this. external-dns-unifi writes the gateway names
(`edge.dcunha.io`, `internal.dcunha.io`, …) as dnsmasq `host-record`s with IPv4 only. It writes
every app name as a `cname` to one of them. dnsmasq answers the A record locally, but it forwards
the AAAA upstream. So a LAN client that can use IPv6 gets whatever public DNS says for the gateway
name (`dig AAAA git.dcunha.io @10.10.99.1`).

The fix (`6086a4b2e`) is a public, grey `edge.dcunha.io CNAME edge.frostlink.dev` in
`kube/clusters/artemis/apps/network/towonel-agent/app/dnsendpoint.yaml`. external-dns-cloudflare
reads it with its `crd` source. The forwarded AAAA then comes back NODATA, and the client uses the
local A. `internal.dcunha.io` has no public record and the wildcard is gone. So its AAAA gets
NXDOMAIN upstream, not a wrong address.

UniFi has no "A only" option for one name, and dnsmasq overwrites a hand edit. So the full fix is
still two changes: gateways with ULA IPv6 addresses, and external-dns-unifi that publishes local
AAAA records. If `edge.frostlink.dev` gets an AAAA one day, IPv6 LAN clients will start to hairpin
through the VPS.

### Remote access — the UCG is the subnet router

The tailnet is self-hosted Headscale on Frostlink (`headscale.frostlink.dev`). The UCG Max is the
home subnet router, `tag:home-router`. It advertises LAB `10.10.99.0/24` and HME `10.10.1.0/24`.
Ansible manages it. See `ansible.md` § The UCG Max role.

Away from home, a Headscale device with subnet routes on reaches every LAB address and every
`*.dcunha.io` gateway name. The split DNS of Headscale sends `dcunha.io` to `10.10.99.1`. This is
how git SSH works remotely. Nothing is port-forwarded. Public `dcunha.io` HTTPS now goes through
towonel, but SSH does not (§ Raw TCP ports on a shared gateway).

- The policy, the split DNS and the device list live in Frostlink, in its `headscale` app and in
  `oci-networking.md` § Tailnet policy.
- arcana keeps subnet routes off. It already has HME and LAB NICs. If it accepts the routes, Windows
  sends that LAN traffic through the tailnet.

### Firewall — traffic rules, not code

The UCG uses the legacy firewall for each network. UniFi manages it as traffic rules (v2 API
`/proxy/network/v2/api/site/default/trafficrules`). The tofu provider models only the zone-based
firewall, so these rules exist only on the live system. Everything is open between networks,
except:

| Rule (description as shown in UniFi)                       | Effect                                                |
| ---------------------------------------------------------- | ----------------------------------------------------- |
| Block CAM VLAN from Internet / to Local Networks           | Cameras reach only frigate. NTP to Cloudflare allowed |
| Block GST VLAN to Local Networks (IoT allowed for casting) | Guest reaches the internet and IOT only               |

The guest rule leaves out IOT on purpose, so guests can cast to TVs and speakers. The mDNS
reflector of UniFi handles discovery. The rule does not block the admin page of the gateway itself,
because traffic rules cannot target it. UniFi rejects the WireGuard network as a traffic-rule target
(`api.err.InvalidNetworkConfId`).

The Mikrotik CRS309 is a plain downstream switch below the UCG. The UCG is the router, the DHCP/DNS
server, the STP root and the mDNS reflector. The switch is managed at `10.10.99.2` on LAB. It is a
DHCP client with a UniFi fixed-IP reservation, and it gets its default route and DNS from the UCG.
There is no routed `/30` TRANSIT link (`172.16.99.x`) any more. The bridge, the VLAN table, the two
remaining VLAN interfaces, the route and the DHCP client are in OpenTofu
(`terraform/stacks/mikrotik`). The credentials are `infrastructure/mikrotik-crs309`. The SSH key of
arcana is on `admin`.

Ports: `sfp-sfpplus1` → UCG, `sfp-sfpplus2` → 48-port UniFi switch (link down), `sfp-sfpplus7` →
atlas (1099 untagged), `sfp-sfpplus8` → pantheon. The pantheon port is a full trunk, as a hypervisor
port must be (VLAN 1 untagged, and 1001, 1062, 1088, 1099, 1151, 1152 tagged).

LLDP stops at the CRS309, so the UniFi topology cannot show what is behind it. Every lab host
advertises itself:

- pantheon uses the ansible role `lldpd`.
- atlas uses a `truenas_app` in the tofu `truenas` stack. TrueNAS 25.10 has no LLDP service and a
  read-only `/usr`.
- Every Talos node uses the `lldpd` DaemonSet in `kube-system`.

The CRS309 lists pantheon, atlas and the three pantheon VMs (`/ip neighbor print`). It sees the VMs
because `group_fwd_mask` of vmbr0 passes LLDP through. The US48 lists ymir and the control-plane
nodes. UniFi draws the topology only from the LLDP tables of its own devices, and port 3 of the UCG
sees only the CRS309. So everything behind the switch shows as a client on UCG port 3, not under the
switch.

The CRS309 is not L2-only for IPv6, and its IOT interface must stay. It owns `fd00:10:10:152::1` on
IOT and advertises the ULA prefix there. Its RA has `ra-lifetime=none`, so it is not a default
router. The static addresses of the `iot` NAD and the Thread/Matter devices use that ULA. The UCG
cannot also hand out a ULA. An earlier RA with a router lifetime is what broke Matter.

IPv6 prefixes come from Rogers DHCPv6-PD on the UCG WAN, and they rotate. Never hardcode a GUA from
them. VLAN 1152 also carries the legacy ULA `fd00:10:10:152::/64`. The Mikrotik still advertises it,
and the static addresses of the `iot` NAD still use it.

### endpointRoutes is off — and turning a Cilium flag off is not symmetric

`endpointRoutes.enabled` is off. netkit, native routing, BPF masquerade and
`socketLB.hostNamespaceOnly` do not need it. With netkit and `socketLB.hostNamespaceOnly` together,
it marks service replies as `CT_NEW` by mistake
([cilium#47913](https://github.com/cilium/cilium/issues/47913)). Two traps made "I turned it off" a
false statement. Both apply to any Cilium flag:

1. Removing the value does not remove the setting. The chart writes the key only when it is true. So
   if you set `false`, the chart leaves the key out, and Helm leaves the old
   `enable-endpoint-routes: "true"` behind in `cilium-config`. `Helm upgrade succeeded` while the
   setting stayed on. The fix is
   `kubectl patch cm -n kube-system cilium-config --type=json -p '[{"op":"remove","path":"/data/enable-endpoint-routes"}]'`,
   and then an agent roll. Make sure of the result in the ConfigMap and in the startup log of the
   agent (`--enable-endpoint-routes='false'`). Never trust the Helm status.
2. Existing pods keep the old delivery path. Cilium cannot rewrite a live endpoint. So the `/32`
   routes for each endpoint to `lxc*` devices stay until each pod is recreated. Both paths work at
   the same time. The same asymmetry applies to `enableIPv4BIGTCP`.

`rollOutCiliumPods: false` is set, so you roll the agents by hand. The values do not set an update
strategy for the agent DaemonSet, so it keeps the chart default `maxUnavailable: 2`. A
`rollout restart` can then take two control planes at once. Delete the agent pods one node at a
time instead.

A trap in the counts: `cilium-dbg metrics list | grep 'Policy denied'` returns two rows,
`cilium_drop_bytes_total` and `cilium_drop_count_total`. Read the count, not the bytes.

### Cilium's VLAN filter and the drop counter

`devices: bond+` attaches Cilium to the parent trunk `bond0` and also to its sub-interfaces. So the
host firewall runs on raw tagged frames, and it drops every tag that Cilium does not manage. Tags
that have a managed device (1099, 1152, 1062) are allowed automatically. Cilium counts the rest as
`cilium_drop_count_total{reason="VLAN traffic disallowed by VLAN filter"}`.

`bpf.vlanBypass: [1001, 1151, 1088]` allows the three trunked VLANs that have no node interface.
Upstream limits the list to 5 entries. `[0]` means allow-all, and it turns the filter off fully.

The bypass only halves the counter. Every VLAN in the table above is managed or bypassed, so the
remaining drops come from something else. The most likely cause is priority-tagged frames (VLAN ID
0). You cannot list them on their own, because `0` is the allow-all value. The team left it as it
is. The drops do no harm, because the host discards those frames anyway. Turning the filter off
fully is not worth a cleaner graph.

For alerting, exclude that `reason` label. Do not alert on total drops.

The agent scans for VLAN devices only at startup. If you add a VLAN sub-interface to the nodes,
Cilium filters its traffic with no warning until the Cilium agents restart.

## Dual-stack (since 2026-09-24)

Pods get IPv6 as well as IPv4. IPv4 stays the primary family. Services stay IPv4-only unless one
opts in with `PreferDualStack`/`RequireDualStack`.

| Range                   | What                                                                                |
| ----------------------- | ----------------------------------------------------------------------------------- |
| `fd00:10:10:99::<N>/64` | Node address on `bond0.1099`, `N` = last IPv4 octet. The kubelet node IP            |
| `fd00:42:1:<n>::/64`    | Pod range for each node, from the `network.cilium.io/ipv6-pod-cidr` node annotation |
| `fd00:42::/56`          | Pod range of kcm. Only a node registered after 2026-09-24 draws from it             |
| `fd00:43::/108`         | Service range. The default ServiceCIDR is now dual and cannot go back               |
| `fd00:42::/32`          | Cilium `ipv6NativeRoutingCIDR`. It must cover both pod ranges above                 |

- An annotation, not `spec.podCIDRs`, sets the pod range. The podCIDRs of a Node can only go from
  empty to set, so existing nodes never get a v6 range from kcm. Cilium reads the annotation because
  `annotateK8sNode: true` is set. If both exist, `spec.podCIDRs` wins. The annotation lives in each
  `kube/clusters/artemis/talos/nodes/<node>.yaml.j2`. Remove it when a node is rebuilt and gets a
  kcm range. `n` is the third octet of the IPv4 podCIDR of the node.
- The routing CIDR is `/32`, not `/48`. `fd00:42::/48` does not contain `fd00:42:1::`, because the
  third hextet is outside it.
- Egress: BPF masquerades pod IPv6 to the Rogers GUA of the node on `bond0.1099`, which rotates.
  The node ULA is never an egress source, because nothing upstream routes `fd00::/8`.
- Cilium does not change running pods. A pod that was created before the Cilium agent of its node
  restarted has no IPv6 until the pod restarts. The command below counts those pods.
- CoreDNS still answers NODATA for every AAAA (§ CoreDNS, Guard 2).
- IPv6 LoadBalancer IPs over BGP are not done. Cilium sends an IPv4 next hop for IPv6 routes on the
  existing sessions, and the UCG has no stable IPv6 to peer with.

### IoT pods drop the Cilium IPv6 default route

With Cilium IPv6 on, a pod on the `iot` NAD gets two IPv6 defaults at the same metric. One is the
Cilium default on `eth0`. The other is the RA of the UCG on `net1`. The kernel merges them into one
ECMP route. Thread traffic (`fdf4:6f68:f055:1::/64`) goes only through the default (see _Thread
routing rides the default route_). So it is hashed across both routes, and the `eth0` half is
masqueraded out of the node.

`home-assistant` and `matter-server` carry an `iot-v6-route` init container. It waits for the `net1`
RA default, and then deletes only the `eth0` nexthop. Nothing else about the pod changes. The RA
stays the source of the default, and cluster IPv6 on `eth0` still works through its connected
routes.

- Delete by `via <gw> dev eth0`, never by `dev eth0` alone. If the RA default is already merged,
  Busybox `ip` removes the whole multipath route. Then `net1` has no default until the next RA.
- It works under `hostUsers: false` (matter-server). The netns of the pod belongs to the user
  namespace of the pod, so `NET_ADMIN` in the init container is enough.
- homebridge, esphome, victoria-logs and bambuddy do not have the init container. They reach IoT
  devices through the on-link `fd00:10:10:152::/64`, which is more specific than either default.
  They do not talk to the Thread mesh. If a new pod talks to the Thread mesh, add the init container
  to it.

## External DNS

The external-dns instances run in `network`. Each instance is pinned to one zone and one provider:

| Deployment                | Zone            | Provider   | Sources                        | `txt-owner-id`    | `txt-prefix`                   |
| ------------------------- | --------------- | ---------- | ------------------------------ | ----------------- | ------------------------------ |
| `external-dns-unifi`      | `dcunha.io`     | webhook    | `gateway-httproute`, `service` | `k8s-internal`    | `k8s.internal.%{record_type}-` |
| `external-dns-cloudflare` | `dcunha.io`     | Cloudflare | `gateway-httproute`, `crd`     | `artemis-cluster` | `k8s.%{record_type}-`          |
| `external-dns-edge`       | `dcunha.io`     | Cloudflare | `gateway-httproute`            | `artemis-edge`    | `k8s.edge.%{record_type}-`     |
| `external-dns-frostlink`  | `frostlink.dev` | Cloudflare | `crd` only                     | `artemis`         | `k8s.artemis.%{record_type}-`  |

- `external-dns-unifi` writes to the UCG-Max. It is what makes `*.dcunha.io` resolve on the LAN. It
  has no `--gateway-name` filter, so it watches every HTTPRoute on every gateway. This is why two
  routes that share one hostname race to own the internal A record.
- `external-dns-cloudflare` is filtered to `--gateway-name=external-gateway` and runs
  `--cloudflare-proxied`. The tunnel is retired and no routes are left on `external-gateway`. So its
  `gateway-httproute` source publishes nothing. What it still owns comes from its `crd` source: the
  grey `status.dcunha.io` (cloudflare-dns DNSEndpoint) and the grey `edge.dcunha.io` (towonel-agent
  DNSEndpoint). Both are CNAMEs to `edge.frostlink.dev`, with `cloudflare-proxied: "false"` on each
  endpoint.
- `external-dns-edge` (app `network/edge-dns`) publishes grey CNAMEs → `edge.frostlink.dev` for
  every `edge-gateway` route. It reads only annotations with the `edge-dns.kubernetes.io/` prefix. So
  the standard `external-dns.kubernetes.io/target` of the gateway stays for `external-dns-unifi`
  (LAN). Details: `towonel-agent.md` § DNS.
- `external-dns-frostlink` serves the zone of the other cluster. Its owner id and prefix must differ
  from those of the instance on frostlink. If they do not, the two instances delete each other's
  records in a loop. `towonel-agent.md` § The collision guard is the authority on that. Do not
  restate it here.

All of them run `--policy=sync`. They delete anything that they think they own and no longer see.

## CoreDNS

Manifest: `kube/clusters/artemis/apps/kube-system/coredns/app/helmrelease.yaml`. It is the upstream
coredns chart with the home-operations plugin chain. The two `template` plugins between `autopath`
and `forward` are ours, and the cluster depends on them. Their reasons live here, not in the
manifest.

### Plugin order is load-bearing

```text
kubernetes → autopath → template(ANY ANY dcunha.io) → template(ANY AAAA .) → forward
```

The order of the two `template` blocks is load-bearing. Guard 1 must come before Guard 2 (see
below). If you swap them, you bring back the cluster-wide outage described below. Their position
relative to `kubernetes` and `forward` in the list does not matter. CoreDNS runs plugins in its
compiled order, where `template` already runs before `kubernetes`.

### Guard 1 — `template ANY ANY dcunha.io`, NXDOMAIN for 2+ label names

Talos 1.14 applies the DHCPv4 search domain, so the `resolv.conf` of every pod now ends with
`dcunha.io`. With `ndots:5`, a name like `postgres-rw.database.svc.cluster.local` (4 dots) goes
through the search list before the resolver tries it as an absolute name. `<anything>.dcunha.io`
resolved through a Cloudflare wildcard. So upstream answered `172.64.80.1` and not the ClusterIP.
glibc callers (immich, paperless, zigbee, forgesync…) broke. busybox/musl was not affected, because
it tries the absolute name first.

The problem is not limited to cluster names. `ghcr.io` (1 dot, also under `ndots:5`) becomes
`ghcr.io.dcunha.io`. The wildcard answered it, and TLS then failed on the certificate mismatch.
That took out every OCIRepository at once. The class of bug is "the resolver added the search domain
to a name that already contains a dot". So the guard answers NXDOMAIN to any name with 2 or more
labels before `dcunha.io`. Real hosts here have a single label (`git`/`id`/`artemis`.dcunha.io), and
they keep resolving normally.

The answer must be NXDOMAIN. A NODATA lets the walk through the search domains continue.

The team deleted the Cloudflare wildcard that caused this on 2026-10-04, with the tunnel. So upstream
now answers these names NXDOMAIN by itself. The guard is still in place.

### Guard 2 is unscoped — `template ANY AAAA .`

Guard 2 matches `.`, which is every zone and not only `dcunha.io`. So every AAAA query gets NODATA
(NOERROR, no answer, no fallthrough). Pods only ever dial IPv4 by name, as they did before
dual-stack. Narrowing it is [#2364](https://git.dcunha.io/Exikle/home-infra/issues/2364).

The guard started for this reason. The internal split-horizon overrides only the A record, so a
public AAAA passed through unchanged. A pod with no IPv6 had no route to that address, and any
client that tried it first failed with "network is unreachable". This happened at random times,
across tasks and hosts that had no relation. The `authority` SOA lets resolvers cache the NODATA,
so they do not ask again on every lookup.

Two constraints hold it in place:

- Its position still matters. It must stay after Guard 1. If it comes first, it answers AAAA for
  `ghcr.io.dcunha.io` with NODATA before Guard 1 can return NXDOMAIN. That breaks the fix for the
  search-domain hijack again.
- It catches `cluster.local` AAAA too, because `template` comes before `kubernetes` in the plugin
  chain of CoreDNS. Services are IPv4-only by default, so NODATA is correct for them. A Service that
  opts into dual-stack loses its AAAA to this guard. List those Services with
  `kubectl get svc -A -o json | jq -r '.items[] | select(.spec.ipFamilyPolicy != "SingleStack") | "\(.metadata.namespace)/\(.metadata.name)"'`.
  The cluster is dual-stack now, so revert this first when you narrow Guard 2.

The condition for narrowing it is that every running pod has IPv6. Before you narrow it, count
the pods that do not:
`kubectl get pods -A -o json | jq '[.items[] | select(.spec.hostNetwork != true and .status.phase == "Running" and (.status.podIPs | length) < 2)] | length'`.
Nothing about Matter blocks it. See _CoreDNS plays no part in Matter_.

### Verifying a CoreDNS change

Test offline before you touch cluster DNS. A bad Corefile crashloops every DNS pod. The chart does
not run `configBlock` through `tpl` (`{{ .configBlock | indent 12 }}`). So Go template variables like
`{{ .Zone }}` reach the Corefile as written, and CoreDNS expands them at query time. Flux `postBuild`
uses `${...}`, so it does not touch them either.

```bash
helm template coredns oci://ghcr.io/coredns/charts/coredns --version <ver> \
  -f <(yq eval '.spec.values' kube/clusters/artemis/apps/kube-system/coredns/app/helmrelease.yaml) \
  --show-only templates/configmap.yaml
```

Then run the rendered Corefile under podman and test each case. Remove the
`kubernetes`/`health`/`prometheus` plugins first, and point `forward` at a public resolver. The
expected results are:

| Query                    | Expected           |
| ------------------------ | ------------------ |
| `A ghcr.io`              | real answer        |
| `AAAA ghcr.io`           | NOERROR, 0 answers |
| `A git.dcunha.io`        | 10.10.99.90        |
| `AAAA git.dcunha.io`     | NOERROR, 0 answers |
| `A ghcr.io.dcunha.io`    | NXDOMAIN           |
| `AAAA ghcr.io.dcunha.io` | NXDOMAIN           |

Make sure of the result live from a glibc pod (`kubectl exec -n database postgres-1 -c postgres`).
musl images resolve names in a different way, and they hide the original class of bug.

## BGP / Control-Plane Endpoint

The UCG-Max runs FRRouting (`vtysh -c "show version"`). You can `ssh root@10.10.99.1` to inspect it
(`vtysh -c "show bgp ipv4 unicast summary"`, `ip route show <ip>`):

| Item                | Value                                                          |
| ------------------- | -------------------------------------------------------------- |
| UCG ASN / router-id | `64533` / `10.10.99.1`                                         |
| Cluster ASN         | `64512` (Cilium, `CiliumBGPClusterConfig`)                     |
| Peers               | eBGP, one neighbour line per node, description = node hostname |
| Hold / keepalive    | `9s` / `3s`                                                    |

### Editing the BGP config — it is not a file on disk

`/etc/frr/frr.conf` on the UCG holds only stock defaults (`log syslog informational`). The real
configuration lives in the MongoDB of the UniFi controller (`/data/unifi/data/db/ace`). The
controller pushes it into FRR. Nothing writes it to disk. So if you `grep` the filesystem for a
neighbour address, you find only DNS leases and logs.

There is no BGP form in the UI. The configuration is a raw FRR file that you upload in the Network
app, under Settings → Routing → BGP. It contains only the `router bgp` block. The controller makes
the surrounding `frr version` / `hostname` / `domainname` lines itself.

A `vtysh -c "configure terminal" -c "router bgp 64533" -c "neighbor ..."` change applies at once and
survives an FRR restart. But the controller overwrites it on the next provision. Use vtysh only to
get a peer up for the moment. The upload is the edit that lasts.

To add a node, add two neighbour lines and one line in `address-family ipv4 unicast`:

```
 neighbor 10.10.99.204 remote-as 64512
 neighbor 10.10.99.204 description ymir
 !
 address-family ipv4 unicast
  neighbor 10.10.99.204 soft-reconfiguration inbound
 exit-address-family
```

Cilium needs no matching change. `CiliumBGPClusterConfig` selects on `kubernetes.io/os: linux`, so
every node is already a speaker. The session comes up as soon as the neighbour exists on the UCG.
To dump the current configuration for a new upload, run:
`ssh root@10.10.99.1 'vtysh -c "show running-config"' | sed -n '/^router bgp/,/^exit$/p'`

A node joins the cluster with its BGP session already broken, and nothing shows it. The node goes
`Ready` and workloads schedule. The only symptom is this: a `externalTrafficPolicy: Local`
LoadBalancer is not reachable when its pod lands on that node. Cilium reports the truth, but only
if you ask for it:

```bash
kubectl get ciliumbgpnodeconfig -o json \
  | jq -r '.items[] | "\(.metadata.name): \(.status.bgpInstances[].peers[].peeringState)"'
```

This hit `ymir`. It stayed `idle` until the team uploaded its `10.10.99.204` neighbour lines. After
you add any node, add the lines. Then run the command above again before you call the node done.

`artemis.dcunha.io` → `10.10.99.99` is a Cilium LoadBalancer Service (`kube-api` in `kube-system`).
It selects apiserver pods with `externalTrafficPolicy: Local`, and BGP advertises it. ECMP already
works. The UCG shows 3 `multipath` paths and 3 kernel next-hops, one for each control plane. The FRR
configuration has no `maximum-paths` line, and it needs none.

BGP agrees on the minimum hold time of the two peers, so the timers of the cluster win. The UCG
offers 180/60 and Cilium proposes 9/3. Do not "fix" this on the router. Before 9/3, the hold time
was 90s. Then a hard control-plane failure (power loss, not a clean withdrawal) black-holed about a
third of API traffic for up to 90 seconds.

### Graceful restart — why `restartTimeSeconds: 30` sits next to a 9s hold time

The UCG already runs as a GR helper (FRR 10.1.2, `Local GR Mode: Helper`). But Cilium never
advertised the capability, so the session showed `Remote GR Mode: Disable`. So every session drop
withdrew every VIP at once, and took `internal-gateway` (10.10.99.98) out with everything else.
`gracefulRestart` in `CiliumBGPPeerConfig/l3-bgp-peer-config` makes the UCG keep the routes as stale
and keep forwarding through a flap.

The 30s value is on purpose. It is a trade against the 9s hold time above. A false flap comes back
in 1–3s and is fully covered. A node that is really dead now black-holes traffic for up to 30s, not
9s. BFD avoids the trade, but the UCG ships no `bfdd` binary, so BFD is not an option.

### ClusterMesh with Frostlink

Removed 2026-11-14 (issue #3082). Nothing used its global services, and public traffic now reaches
Artemis over the towonel backhaul (`towonel-agent.md`). The mesh LoadBalancer `10.10.99.93` and the
shared CA secret are gone. These leftovers are still in the Cilium values, and they do no harm:

- The cluster `id` and `name`. Changing them gives every endpoint a new identity.
- BGP advertises `PodCIDR` as well as `LoadBalancerIP` (`kube-system/cilium/app/network.yaml`).
- ip-masq-agent `nonMasqueradeCIDRs: [10.42.0.0/16]` with `masqLinkLocal: true`. Pod → LAN traffic
  is still masqueraded to the node IP. Do not widen `ipv4NativeRoutingCIDR` instead. Cilium checks
  the native CIDR before ip-masq-agent. So pod → LAN traffic stops being masqueraded, and LAN hosts
  reply through the UCG.
- `directRoutingSkipUnreachable: true` and `bpf.lbModeAnnotation: true`.

### Declined: anycast control-plane endpoint via Talos native BGP

Do not open this again without new information. Cilium cannot advertise `10.10.99.99` unless the
API server is already up. So the endpoint is not available during a cold start or a total Cilium
outage. Workers point at `https://artemis.dcunha.io:6443`, so they cannot join while it is down.
Talos 1.14 native BGP runs without Kubernetes and can close that gap, but:

- Talos and Cilium sessions to one UCG neighbour collide. `BGPPeerConfig` has no source-address
  field, both sessions come from `bond0.1099`, and BGP collision resolution tears one down.
  Unnumbered peering does not fix it for IPv4, because Talos has no RFC 5549 support.
- To close the gap, you need a new peering VLAN, or a BGP split by role, so that control planes run
  only the Talos session. The split leaves a `externalTrafficPolicy: Local` LoadBalancer silently
  unreachable when its pod lands on a control plane. That is a permanent constraint on scheduling.
- ECMP already works and the hold timers are 9s, so failover in normal running is fine. The change
  is not worth the cost.

`etp: Local` matters for more than scheduling. Cilium runs `loadBalancer.mode: dsr` with the default
`opt` dispatch. That dispatch puts the original address in an IPv4 option that only Cilium uses.
Upstream warns that routers can punt or drop such packets. It is safe for north-south traffic only
because `etp: Local` never needs the forwarding path to a remote backend that DSR exists for. A
LoadBalancer with the Kubernetes default (`etp: Cluster`) sends packets with IP options across the
UCG-Max. That shows up as loss on one service that comes and goes with load. Set `etp: Local` on
every north-south LoadBalancer, or change the dispatch mode first. There is no `etp: Cluster`
LoadBalancer now. The ClusterMesh one was removed. List them with
`kubectl get svc -A --field-selector spec.type=LoadBalancer -o custom-columns=NS:.metadata.namespace,N:.metadata.name,ETP:.spec.externalTrafficPolicy`.

Gateway replicas are not pinned. So the nodes that they land on change with every reschedule
(`kubectl get pods -n network -o wide -l gateway.envoyproxy.io/owning-gateway-name`).

## Multus — IoT VLAN Attachment

Some pods need direct L2 access to IoT VLAN 1152, for example home-automation apps and Matter
Server. Multus gives them a second interface, `net1`. The network attachment definition (NAD) is
named `iot`, in `kube-system`.
A second NAD, `cam` in `kube-system`, puts frigate on the camera VLAN 1062. Every node has a
`bond0.1062` interface (`kube/clusters/artemis/talos/cluster.yaml.j2`), so frigate can run on any
node that its GPU selector allows. Its node selector is `node.kubernetes.io/gpu-tier: gen9`. It
gets the HD 530 iGPU through a DRA (dynamic resource allocation) claim from the `frigate-igpu`
ResourceClaimTemplate (`gpu.intel.com`, PCI ID `0x1912`). See `gpu.md`.

### Annotation format

```yaml
defaultPodOptions:
    annotations:
        k8s.v1.cni.cncf.io/networks: |-
            [{
              "name": "iot",
              "namespace": "kube-system",
              "ips": [
                "10.10.152.<N>/24",
                "fd00:10:10:152::<N>/64"
              ],
              "mac": "02:xx:xx:xx:xx:xx"
            }]
```

- IPv4: `10.10.152.<N>/24`. Pick the next free address in the static range.
- IPv6: `fd00:10:10:152::<N>/64`. It always matches the last IPv4 octet. Write `<N>` in decimal. No
  conversion is needed for values ≤ 255.
- MAC: static, and you assign it by hand. Use the `02:` prefix (locally administered unicast). Keep
  it unique across all pods.
- Gateway (IPv4): `10.10.152.1` (the IoT VLAN interface of the UCG-Max).
- IPv6 default route: learned through RA from the UCG-Max (`fd00:10:10:152::1`).

### Assigned addresses

| App            | IPv4            | IPv6                  | MAC               |
| -------------- | --------------- | --------------------- | ----------------- |
| home-assistant | 10.10.152.10/24 | fd00:10:10:152::10/64 | 02:4d:60:06:55:be |
| matter-server  | 10.10.152.11/24 | fd00:10:10:152::11/64 | 02:0c:d8:a2:91:8f |
| homebridge     | 10.10.152.12/24 | fd00:10:10:152::12/64 | 02:ee:bb:51:b4:dc |
| esphome        | 10.10.152.13/24 | fd00:10:10:152::13/64 | 02:4d:60:0e:5e:0d |
| victoria-logs  | 10.10.152.14/24 | fd00:10:10:152::14/64 | 02:1a:c3:7f:9e:44 |
| bambuddy       | 10.10.152.15/24 | fd00:10:10:152::15/64 | 02:a5:d2:b4:e5:40 |

Next free: `.16` / `::16`

### Thread / Matter context

The IoT VLAN hosts the Thread mesh through three border routers:

| Device            | IP            | MAC               | Link-local IPv6           | TBR policy  |
| ----------------- | ------------- | ----------------- | ------------------------- | ----------- |
| Apple TV Basement | 10.10.152.166 | 48:e1:5c:76:22:2b | fe80::4ae1:5cff:fe76:222b | Restrictive |
| Nest Hub #EB53    | 10.10.152.86  | 38:86:f7:0e:96:93 | fe80::3a86:f7ff:fe0e:9693 | Open        |
| Nest Hub #2960    | 10.10.152.99  | d8:eb:46:d6:b9:4c | fe80::daeb:46ff:fed6:b94c | Open        |

Thread network: `NEST-PAN-0751`, Channel 22, Extended PAN ID `7fd8ca45c6794b90`

Apple TV blocks third-party Matter commissioning through Thread. Route through a Nest Hub instead.

### Thread routing rides the default route — do not remove it

The pod does not learn the Thread mesh prefix (`fdf4:6f68:f055:1::/64`) from RA as a specific route.
`net1` carries `accept_ra_rt_info_max_plen=0`, so the kernel ignores the RFC 4191
route-information options of the border routers. Matter reaches Thread devices through the IPv6
default route of the pod. So the Matter fabric depends on `::/0` on `net1`.

That default does not come from the NAD. The `iot` NAD declares
`{"dst": "::/0", "gw": "fe80::58d6:1fff:fe27:c2e3"}`, but `sbr` never applies it. `sbr` copies a
route into the sbr table only when the address prefix of the pod contains the gateway. A
link-local gateway is not inside `fd00:10:10:152::/64`. The only IPv6 default is in `main`:
`via fe80::58d6:1fff:fe27:c2e3 dev net1 metric 1024 expires 0sec`. It is a Router Advertisement, not
a CNI route. So the `::/0` line of the NAD does nothing. Leave it alone, because removing it is a
live change to a NAD that carries Matter, for no gain. No fallback route from the CNI exists behind
the RA, so the trap below is real.

### The `sbr` link-local trap — read before changing RA on VLAN 1152

The `iot` NAD chains the `sbr` (source-based routing) plugin. The plugin creates
`ip -6 rule: from fd00:10:10:152::10 lookup 101`, and it puts `fe80::/64 dev net1` in table 101
only. Matter uses the link-local address of net1 as the source when it talks to link-local peers.
That address does not match the rule, so the traffic falls through to `main`. There, the default
route learned from RA is the only net1 entry that catches it.

The result: if you remove the last IPv6 default router from VLAN 1152, Matter breaks. This happens
even though nothing about the change looks related to DNS or Matter. The symptom is
`send ENETUNREACH fe80::...%net1:5540`, and devices that go offline and come back in cycles.

If this comes up again, follow this safe sequence:

1. Make sure that another router already advertises a default on the VLAN. Run
   `kubectl exec -n home-automation deploy/home-assistant -c app -- ip -6 route show | grep default`
2. Demote the router first (`ra-preference=low`). Make sure that clients moved. Only then set
   `ra-lifetime=0s`
3. Leave the Talos hosts alone. They already ignore the RA default on 1152 and 1062
   (`accept_ra_defrtr: "0"` in `kube/clusters/artemis/talos/cluster.yaml.j2`). macvlan children
   have their own netns and `accept_ra`, so that sysctl does not affect the Matter pods

### CoreDNS plays no part in Matter

Matter/Thread discovery is mDNS over multicast (`ff02::fb`). It uses the resolver of the CHIP stack
itself. The pods run `hosts: files dns` with no mDNS NSS module. The `fd00:10:10:152::/64` and
Thread ULA ranges have no unicast DNS records in either direction. So CoreDNS changes cannot affect
the Matter fabric, and Guard 2 does not need to stay wide for it.

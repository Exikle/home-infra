# Reference: Frostlink networking

## Gateway

Frostlink has one gateway: `external-gateway` in the `network` namespace. There is no
internal-gateway.

- It is the front door. Artemis issue #3082 has the decision and the history. It owns the public 80
  and 443 of the node. The Envoy Service is `ClusterIP` with `externalIPs: [10.0.0.203]` (the
  `envoyService.patch` in `envoy-gateway/app/envoy.yaml`). The kube-proxy replacement of Cilium
  serves that address. See _The front door_ below.
- TLS certs: `frostlink-dev-tls` and `dcunha-io-tls`. Both are imported or issued in `network`. See
  _Wildcard cert_ below. Envoy terminates TLS for both domains.
- HTTP listener: `allowedRoutes.namespaces.from: Same` (the network namespace only). The HTTPS
  redirect HTTPRoute handles it.
- HTTPS listener: `allowedRoutes.namespaces.from: All`. Routes from all namespaces can attach.
- `headscale` listener: TLS passthrough on the same port, for `headscale.frostlink.dev` only. See
  _Headscale ingress_.
- CrowdSec runs on the whole gateway (`kube/clusters/frostlink/components/envoy/crowdsec`,
  `crowdsec.md`). `kube/clusters/frostlink/components/envoy/response-hardening` adds the response
  headers.

Routes attach to `external-gateway` in `network`. They are defined inline in the HelmRelease
values, under `route.app:` (`frostlink.md`).

## DNS

### external-dns-cloudflare

The app directory is `kube/clusters/frostlink/apps/network/cloudflare-dns/`. The Deployment is
named `external-dns-cloudflare`. Search for that name when you inspect the cluster. The flags are in
`cloudflare-dns/app/helmrelease.yaml`. These flags cause trouble:

- `--policy sync`. It deletes records that it believes it owns.
- `--gateway-name external-gateway`. It ignores routes on any other gateway.

There is no `--cloudflare-proxied`. So every record is grey (DNS-only) and points at the node.

The DNS target annotation on the gateway is `external-dns.kubernetes.io/target: external.frostlink.dev`.
`DNSEndpoint/front-door` (`envoy-gateway/app/dnsendpoint.yaml`) makes `frostlink.dev` and
`external.frostlink.dev` CNAMEs to `edge.frostlink.dev`. `edge.frostlink.dev` is a grey A record
to the public IP of the node. To test it, run `dig +short frostlink.dev @1.1.1.1`. A Cloudflare
address (`104.x` or `172.64.x`) means that a record went orange.

The `frostlink.dev` apex record was made by hand in Cloudflare. It has no external-dns owner TXT
record, so external-dns does not manage it. Change it in Cloudflare.

A `target` annotation on one HTTPRoute does not override that. In the `gateway-httproute` source,
the target comes from the _Gateway_, and external-dns ignores the annotation on the route. If a
record needs a different target, put it in a `DNSEndpoint`, and let the `crd` source publish it. Set
grey with `providerSpecific` on the endpoint itself. external-dns ignores an annotation on the
DNSEndpoint object.

`status.dcunha.io` is a grey CNAME to `edge.frostlink.dev`. Artemis writes it
(`cloudflare-dns/app/dnsendpoint.yaml`). The public `dcunha.io` records come from the `edge-dns` of
Artemis, and they are also grey CNAMEs to `edge.frostlink.dev`.

### The `frostlink.dev` zone is shared with Artemis

Artemis runs a second external-dns (`external-dns-frostlink`) against this same zone, also with
`policy: sync`. The two do not fight, because they differ in both the owner id and the TXT prefix:

| Instance                            | `txt-owner-id` | `txt-prefix`                  |
| ----------------------------------- | -------------- | ----------------------------- |
| frostlink `external-dns-cloudflare` | `frostlink`    | `k8s.%{record_type}-`         |
| Artemis `external-dns-frostlink`    | `artemis`      | `k8s.artemis.%{record_type}-` |

The same prefix with different owner ids causes a loop. Each instance overwrites the registry TXT
records of the other, and then deletes the entries of the other. Do not change either value on this
side. `towonel-agent.md` § The collision guard on Artemis is the authority.

Artemis removed its `*.frostlink.dev` wildcard on 2026-11-12
(`dig +short zz-none.frostlink.dev @1.1.1.1` returns nothing). A new Frostlink app needs its own
explicit record. Any HTTPRoute on `external-gateway` gets one automatically. A manual `DNSEndpoint`
gets one only if you write it.

### Wildcard cert

cert-manager issues the `*.frostlink.dev` wildcard cert through Cloudflare DNS-01. The
`Certificate` (`frostlink-dev`) is in `network`, next to the gateway. It writes the secret
`frostlink-dev-tls` there. A PushSecret backs that secret up to the 1Password item
`frostlink-dev-tls`. On a rebuild, the `certificates-import` ExternalSecret (`CreatedOnce`,
`Orphan`) restores it from 1Password before `certificates-export` runs. So cert-manager adopts the
existing cert and does not request a new one. Manifests: `kube/clusters/frostlink/apps/network/certificates/`.

Frostlink does not issue the `dcunha.io` cert. Artemis issues it (`Certificate/dcunha-io` in
`kube/clusters/artemis/apps/network/certificates/export/`), and an Artemis PushSecret writes it to
the 1Password item `dcunha-io-tls`. On Frostlink, the `dcunha-io-tls` ExternalSecret in
`kube/clusters/frostlink/apps/network/certificates/import/externalsecret.yaml` reads that item. So
every public `*.dcunha.io` TLS handshake on Frostlink depends on Artemis renewing the cert. If
Artemis stops renewing it, the Frostlink copy expires.

## CoreDNS suppresses AAAA — the cluster is IPv4-only

`cilium-config` has `enable-ipv6=false`, and the node has a single IPv4 podCIDR (`10.244.0.0/24`).
The node itself has no global IPv6 address. So pods get a link-local `fe80::` address on eth0 and
nothing routable.

CoreDNS forwards to `169.254.169.254`, and that resolver returns AAAA records for external names. A
pod that dials one gets `connect: network is unreachable` at once. The `loadbalance` plugin shuffles
the record order on each response. So the failure is random per response, not fixed. It hit Kopiur
backups to Cloudflare R2 from time to time. It showed as `kopiaErrorClass: RepositoryUnavailable` /
`dial tcp [2606:4700:113::1]:443: connect: network is unreachable`. For a long time it looked like
a credential fault or a repository fault. It is neither.

The `template IN AAAA` plugin with `rcode NOERROR` returns NODATA for every AAAA query. So no pod
ever gets an address that it cannot reach. On an IPv4-only cluster this costs nothing, because no
client can use the answer.

Two caveats:

- The `template` plugin runs before `kubernetes` in the fixed plugin chain of CoreDNS. The plugin
  order comes from `plugin.cfg`, not from the order in the Corefile. So the plugin also answers AAAA
  for `cluster.local`. That is correct on Frostlink, because those services are IPv4-only too. But
  the block is cluster-wide, not only external. If you do not want that, scope it with a zone
  argument (`template IN AAAA cloudflarestorage.com`).
- If you remove the AAAA suppression, expect the Kopiur failures to come back.

## cilium `rollOutCiliumPods` is false

It is `false` to match Artemis. With `true`, every cilium Helm reconcile restarts the agent. During
the restart, the socketLB BPF service map is empty for a short time. A pod that connects to a
ClusterIP then fails with `EPERM` (`connect: operation not permitted`), not with a refusal or a
timeout. On a single node there is nowhere to move traffic while that happens. So the restart is a
short cluster-wide outage, for no benefit. A roll of the agent on a values change is a convenience,
not a requirement. When a cilium change needs a restart, restart the agent on purpose.

Read `EPERM` on a ClusterIP dial as "socketLB found zero backends", not as a NetworkPolicy denial.

## cilium `devices` and `MTU` are pinned

The Cilium HelmRelease sets `devices: enp0s6` and `MTU: 1500`. Without them, device auto-detection
also picks up `tailscale0`. Cilium then sizes every pod interface to the smallest device that it
detects, which is the 1280 of tailscale. `enp0s6` runs at 9000.

- Why 1500 and not 9000: 1500 is the internet path MTU out of the OCI VCN. So pod egress never
  depends on path-MTU discovery. Nothing on this single node needs jumbo frames between pods.
- `tailscale0` stays out of `devices`. Pods have no path over the tailnet (§ Tailnet policy —
  Headscale). If you make `tailscale0` a Cilium device, Cilium puts BPF masquerade on the tailnet
  path, and that path hits an open tcx bug.
- An MTU change reaches an existing pod only when the pod is recreated. The agent restart moves the
  host-side `lxc*` interfaces. Frostlink needs that restart because `rollOutCiliumPods` is false.
  But the own `eth0` of each pod keeps its old MTU until the pod is replaced. To read it, run
  `kubectl exec <pod> --context frostlink -- cat /sys/class/net/eth0/mtu`.

## cilium cluster identity: `id: 2`, `name: frostlink-vps`

Artemis is `id: 1`. Both values are left over from ClusterMesh (removed 2026-11-14), which needed
them to be unique. They stay, because a change gives every endpoint a new identity for no gain.

- Change the ID and the name together, never the ID alone. The name is a pod identity label
  (`io.cilium.k8s.policy.cluster`). The ID is not. After an ID-only change, the existing
  identities still match, and Cilium uses them again, with the old numbers. A restart of the
  workloads does not help (Cilium maintainer, cilium/cilium#48801). A change of the name forces new
  identities.
- No reboot. Apply the values. Then restart `deploy/cilium-operator` and `ds/cilium` by hand
  (`rollOutCiliumPods` is false). Every endpoint gets a new identity on the agent restart. Cilium
  garbage-collects the old identities on its own.
- Make sure that the range is correct. The identities of cluster N are `N*65536 … N*65536+65535`,
  so cluster 2 is `131072–196607`. `cilium-dbg endpoint list -o json` shows the `identity.id` of
  each endpoint.

## The front door

The Cloudflare Tunnel is gone. Public traffic reaches the node directly, and Envoy takes it.

- Envoy owns public 80 and 443. The towonel edge still binds host 443 and 80 (chart values). But a
  BPF path sends that traffic to Envoy, so the edge no longer receives it. Moving the edge off
  those ports is parked, because of the risk to the advertised address.
- Envoy serves the Frostlink apps with their own HTTPRoutes.
- Home (Artemis) apps go over a private path. `towonel/home-backhaul` has the Services
  `artemis-backhaul` and `artemis-backhaul-apex`. Both point at the towonel pod on `:15001`. The
  Artemis agent publishes one TCP service, `artemis-backhaul`, on edge port 15001. It lands on the
  Artemis `edge-gateway.network.svc.cluster.local:443`. The HTTPRoutes `*.dcunha.io` and
  `dcunha.io` send traffic there.
- Re-encryption: BackendTLSPolicies check the Artemis certificate. The SNI is `edge.dcunha.io`. The
  apex Service uses the SNI `dcunha.io`, because the Artemis `edge-gateway` has a separate apex
  listener.
- When home is down: a BackendTrafficPolicy runs a TCP health check with a 3 s connect timeout. A
  502, 503 or 504 becomes the `home-down` ConfigMap page. Do not point the backhaul at the Artemis
  `internal-gateway`. `edge-gateway` is the list of public Artemis apps.
- Real client IPs: the Artemis `ClientTrafficPolicy/edge` trusts `X-Forwarded-For` from the pod
  CIDR of the agent. So its per-IP rate limits see real clients. Without it, every client shares one
  limit. There is no PROXY protocol, no CrowdSec and no towonel hostname claim on Artemis now. For
  the details, read the Artemis `.agents/references/towonel-agent.md`.

## Oracle Cloud VCN

These facts were compared against the OCI console.

- Security list ingress. Every rule is stateful, from `0.0.0.0/0`, with source port All, unless
  noted:
    - `443/tcp`: the front door. Envoy terminates TLS. Headscale passes through.
    - `80/tcp`: Envoy, for the HTTP→HTTPS redirect (`https-redirect` HTTPRoute). The source port
      must be All. A rule with source port `80` matches almost nothing, because clients send from
      an ephemeral port.
    - `51820/udp`: towonel iroh QUIC, where agents connect. If the UDP half is missing, the
      failure is silent.
    - `50000/tcp`: the Talos API. On day 2, `talosconfig` points at `10.0.0.203` over the site
      link. This public rule is the break-glass path when the tailnet is down. It is also the only
      way in during a rebuild (`oci-rebuild.md` § Rebuild order). If you close it, you remove
      both.
    - `6443/tcp` is closed. You open it to your home /32 only for the length of a rebuild.
    - `22/tcp`: dead weight. Talos runs no SSH daemon.
    - `icmp` 3,4 (path MTU) and `icmp` 3 from `10.0.0.0/16`.
- Closed on purpose:
    - `8443/tcp`: the towonel hub API is bound on the host, but it speaks plain HTTP. Clients reach
      it through Envoy at `hub.frostlink.dev`. If you open this port, you expose the operator API
      in cleartext.
    - `6443/tcp`: removed. `kubeconfig` uses `10.0.0.203` over the Headscale site link, so the
      Kubernetes API never needed to be public.
- Security list egress: all allowed. Egress carries Tailscale, which starts its connections
  outbound and has no ingress rule of its own.

Stateless rules break this. OCI skips connection tracking for any flow that matches a stateless
rule, and a stateless rule takes precedence over a stateful one.

The node has its own second layer: a Talos ingress firewall. It keeps every TCP port except
80/443/50000 internal-only (`oci-talos.md` § Host ingress firewall). If you open a port here, the
Talos rule must also allow it.

### Egress budget alerts

`OciEgressBudgetHigh` (7 to 9 TB) and `OciEgressBudgetCritical` (over 9 TB) are in
`observability/vm-alert/app/vmrule.yaml`. They watch the transmit bytes of `enp0s6` over 28d,
against the 10 TB Always Free allowance. `enp0s6` is the closest proxy for what Oracle bills. It
over-counts, which is the safe direction.

The window is 28d, not 30d. vm-single keeps exactly 30d, and a `[30d]` range sits on the boundary
where the oldest samples expire. The warning is bounded (`> 7` and `<= 9`). So it hands off to the
critical alert, and the two do not fire together. An Alertmanager `inhibit_rule` cannot do this,
because the two alertnames differ. Video through the front door moves the number. But the real
limit is the residential upload of Artemis.

## Access Methods

| Access type            | Method                                   | Address              |
| ---------------------- | ---------------------------------------- | -------------------- |
| Kubernetes API         | Headscale site link (from home)          | `10.0.0.203:6443`    |
| Talos API              | Headscale site link (from home)          | `10.0.0.203:50000`   |
| Talos API, break-glass | Public IP, while the OCI rule stays open | `40.233.88.33:50000` |

How "from home" works: your workstation on HME (`10.10.1.0/24`) sends to `10.0.0.203` through its
default gateway, the UCG Max. The UCG is a Headscale subnet router. It accepts the `10.0.0.203/32`
route that Frostlink advertises. The policy grants HME (`10.10.1.0/24`) → `10.0.0.203/32` on
tcp 6443 and tcp 50000 only. LAB (`10.10.99.0/24`) has no such grant. SNAT is off on both routers,
so Frostlink sees the real LAN source.

Away from home, a Headscale device with subnet routes accepted (the iPhone) reaches `10.0.0.203`
directly over the tailnet. If Headscale itself is down, the public Talos port is the only
break-glass path.

## Tailnet policy — Headscale

Every device is on Headscale. No Tailscale SaaS tailnet remains. The policy is checked in at
`kube/clusters/frostlink/apps/network/headscale/app/resources/policy.hujson`. It is mounted into
the Headscale pod at `/etc/headscale/policy.hujson`. § Headscale ingress says how clients reach the
server. To list the live devices, run
`kubectl --context frostlink -n network exec deploy/headscale -c app -- headscale nodes list`. The
node is `tag:frostlink`, the UCG Max is `tag:home-router`, and the rest are the user `exikle`.

The tailnet is for remote admin access (Artemis #3082). Public traffic never uses it. The policy
was rewritten from scratch on 2026-11-14:

- Your own devices (`autogroup:member`) reach each other (`autogroup:self`), both routers, HME,
  LAB, the Frostlink node, and the internet through the home exit node. They reach nothing else. A
  family device added to Headscale also lands in this group. So give a family device its own grant.
- HME → the Frostlink node allows only kubectl (6443) and talosctl (50000). That is the path of the
  workstation. LAB has no reason to reach the node.
- Tagged devices (Frostlink, the home router) have no grants of their own. They answer, and they
  never start a connection.
- Frostlink pods have no path to home. #3297 removed the `10.244.0.0/24` route and its grants,
  after the status page moved to "home reports in" (`status-page.md`). A new Frostlink → home
  dependency goes through the front door, not the tailnet. A pod that still tries the tailnet gets
  a connection timeout, never an error.

The `tests` block of the policy asserts that the admin paths stay open and that the tagged devices
stay shut.

Before you commit a policy edit, test it with the own checker of Headscale. The running server can
test a file without loading it. The image has no shell, so pipe the file in:
`kubectl --context frostlink -n network exec -i deploy/headscale -c app -- headscale policy check -f /dev/stdin < policy.hujson`.
The checker (0.29.7) has two traps:

- A failing test blocks only `policy check` and a SIGHUP reload. A policy change reaches the pod as
  a ConfigMap update, and Reloader restarts Headscale. At startup, a failing test only logs a
  warning, and Headscale applies the policy anyway. Run the check before every apply.
- The test engine ignores the protocol. A grant with `icmp:*` makes every TCP port to that
  destination test as ALLOWED. The real packet filter is not widened (tested from a pod). Do not
  write deny tests against a destination that has an `icmp:*` grant from the same source. A test
  `src` that is the own LAN IP of a member device is treated as that device.

Existing tailnet connections survive a Headscale restart. But phones can report the exit node as
down for a short time.

DNS: `override_local_dns: false`. Devices keep their own resolver for everything except MagicDNS
names and the split domains. The global `1.1.1.1`/`9.9.9.9` are only a fallback.

### Split DNS

`dns.nameservers.split` in the Headscale configuration sends `dcunha.io` to `10.10.99.1`, the UCG,
the same as the SaaS tailnet did. That is how `*.dcunha.io` names resolve on a device away from
home.

- The dnsmasq of the UCG must listen on `tailscale0`. UniFi generates an `interface=` list of LAN
  bridges with `bind-dynamic`. So a query that arrives over the tailnet gets no answer. UDP is
  ignored and TCP is reset. Clients resolve through the resolver of Tailscale, which forwards over
  the tailnet. So this breaks name resolution for every Headscale client, even at home. The fix is
  an `interface=tailscale0` drop-in. The `ucg_tailscale` Ansible role of Artemis manages it.
- Devices that never leave home keep `--accept-routes` off. With it on, Windows prefers the tailnet
  route for HME/LAB over the directly connected network, so LAN traffic loops through the UCG.
  Arcana runs with it off. Split DNS and tailnet IPs still work without it.
- Devices that roam keep it on. The iPhone and grimoire (the Mac) need the routes away from home.
  macOS keeps its own connected subnet on `en0`. So at home on HME, only LAB (`10.10.99.0/24`) and
  `10.0.0.203` go through the tailnet. That is a short hop to the UCG over the LAN
  (`route -n get 10.10.99.1` shows `utun`, `10.10.1.1` shows `en0`).

## Headscale ingress

`headscale.frostlink.dev` is a TLS passthrough on the front door. The `headscale` listener on
`external-gateway` (protocol `TLS`, mode `Passthrough`, same port 443) and a `TLSRoute` in the
Headscale HelmRelease send the raw stream to `headscale.network.svc.cluster.local:443`. The
listener accepts routes only from the `network` namespace.

- Headscale terminates TLS itself, with the `frostlink-dev-tls` wildcard mounted from `network`. It
  reads the certificate only at startup. So the Deployment carries `reloader.stakater.com/auto`. A
  cert-manager renewal rewrites the Secret, and Reloader restarts the pod. Without that, Headscale
  serves the old certificate until it expires.
- Envoy does not terminate it. The Tailscale control protocol is an HTTP upgrade
  (`Upgrade: tailscale-control-protocol`) on a long-lived connection. So it must not go through
  Cloudflare or the HTTP path of Envoy. That is why the route is a `TLSRoute`, and the DNS record is
  a grey `DNSEndpoint` CNAME to `edge.frostlink.dev` (`network/headscale/app/dnsendpoint.yaml`).
- HTTP features of the whole gateway do not apply to it. CrowdSec and `response-hardening` work on
  HTTP, and they do not inspect a passthrough stream.
- The own tailscale of the node logs in through this path. If the front door is down, new tailnet
  logins fail. `oci-rebuild.md` says why a rebuild cannot use this path.
- DERP is the public map of Tailscale, and the embedded DERP is off. The embedded server needs
  public `3478/udp` for STUN, which is not open on OCI. So relayed traffic crosses the DERP servers
  of Tailscale Inc. It is still end-to-end WireGuard-encrypted.

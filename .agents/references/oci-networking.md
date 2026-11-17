# Reference: Frostlink networking

## Gateway

Frostlink has **one gateway**: `external-gateway` in the `network` namespace. There is no internal-gateway.

- It is the front door (Artemis issue #3082 has the decision and history). It owns the node's
  public 80 and 443. The Envoy Service is `ClusterIP` with `externalIPs: [10.0.0.203]` (the
  `envoyService.patch` in `envoy-gateway/app/envoy.yaml`), and Cilium kube-proxy replacement serves
  that address. See _The front door_ below.
- TLS certs: `frostlink-dev-tls` and `dcunha-io-tls` (both imported or issued in `network`; see
  _Wildcard cert_ below). Envoy terminates TLS for both domains.
- HTTP listener: `allowedRoutes.namespaces.from: Same` (network namespace only) — handled by the HTTPS redirect HTTPRoute
- HTTPS listener: `allowedRoutes.namespaces.from: All` — all namespaces can attach routes
- `headscale` listener: TLS passthrough on the same port, for `headscale.frostlink.dev` only.
  See _Headscale ingress_.
- CrowdSec runs on the whole gateway (`kube/clusters/frostlink/components/envoy/crowdsec`, `crowdsec.md`).
  `kube/clusters/frostlink/components/envoy/response-hardening` adds the response headers.

Routes attach to `external-gateway` in `network` and are defined **inline in helmrelease values**
under `route.app:` (`frostlink.md`).

## DNS

### external-dns-cloudflare

The app directory is `kube/clusters/frostlink/apps/network/cloudflare-dns/`; the **Deployment is named
`external-dns-cloudflare`** — search for the latter when inspecting the cluster. Flags are in
`cloudflare-dns/app/helmrelease.yaml`; the ones that bite: `--policy sync` (it **deletes** records
it believes it owns), `--gateway-name external-gateway` (routes on no other gateway). There is no
`--cloudflare-proxied`, so **every record is grey** (DNS-only) and points at the node.

DNS target annotation on the gateway: `external-dns.kubernetes.io/target: external.frostlink.dev`.
`DNSEndpoint/front-door` (`envoy-gateway/app/dnsendpoint.yaml`) makes `frostlink.dev` and
`external.frostlink.dev` CNAMEs to `edge.frostlink.dev`, which is a grey A record to the node's
public IP. Check with `dig +short frostlink.dev @1.1.1.1`: a Cloudflare address (`104.x` or
`172.64.x`) means a record went orange.

**The `frostlink.dev` apex record was made by hand in Cloudflare.** It has no external-dns owner
TXT record, so external-dns does not manage it. Change it in Cloudflare.

**A `target` annotation on an individual HTTPRoute does not override that.** In the
`gateway-httproute` source the target comes from the _Gateway_, and the per-route annotation is
ignored. If a record needs a different target, put it in a `DNSEndpoint` and let the `crd` source
publish it. Set grey with `providerSpecific` on the endpoint itself (an annotation on the
DNSEndpoint object is ignored).

`status.dcunha.io` is a grey CNAME to `edge.frostlink.dev`, written by Artemis
(`cloudflare-dns/app/dnsendpoint.yaml`). The public `dcunha.io` records come from Artemis
`edge-dns` and are grey CNAMEs to `edge.frostlink.dev` too.

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

Artemis removed its `*.frostlink.dev` wildcard on 2026-11-12 (`dig +short zz-none.frostlink.dev
@1.1.1.1` returns nothing). A **new Frostlink app needs its own explicit record**. Any
HTTPRoute on `external-gateway` gets one automatically; a manual `DNSEndpoint` does not unless you
write it.

### Wildcard cert

`*.frostlink.dev` wildcard cert issued by cert-manager via Cloudflare DNS-01. The `Certificate`
(`frostlink-dev`) lives in `network`, next to the gateway, and writes the secret
`frostlink-dev-tls` there. A PushSecret backs that secret up to the 1Password item
`frostlink-dev-tls`; on a rebuild the `certificates-import` ExternalSecret (`CreatedOnce`,
`Orphan`) restores it from 1Password before `certificates-export` runs, so cert-manager adopts the
existing cert instead of requesting a new one. Manifests: `kube/clusters/frostlink/apps/network/certificates/`.

## CoreDNS suppresses AAAA — the cluster is IPv4-only

`cilium-config` has `enable-ipv6=false` and the node has a single IPv4 podCIDR
(`10.244.0.0/24`); the node itself has no global IPv6 address. Pods therefore get a link-local
`fe80::` on eth0 and nothing routable.

CoreDNS forwards to `169.254.169.254`, which happily returns **AAAA** records for external names.
A pod that dials one gets `connect: network is unreachable` instantly. Because the `loadbalance`
plugin shuffles record order per response, this is a per-response dice roll rather than a
deterministic failure — it hit Kopiur backups to Cloudflare R2 intermittently, surfacing as
`kopiaErrorClass: RepositoryUnavailable` /
`dial tcp [2606:4700:113::1]:443: connect: network is unreachable` and looked for a long time like
a credential or repository fault. It is neither.

The `template IN AAAA` plugin with `rcode NOERROR` returns NODATA for every AAAA query, so no pod
is ever handed an address it cannot reach. On an IPv4-only cluster this costs nothing — there is
no client that could have used the answer.

Two caveats worth keeping:

- The `template` plugin runs **before** `kubernetes` in CoreDNS's fixed plugin chain (plugin
  ordering comes from `plugin.cfg`, not from the order in the Corefile), so it also answers AAAA
  for `cluster.local`. That is correct on Frostlink — those services are IPv4-only too — but it means the
  block is genuinely cluster-wide, not just external. Scope it with a zone argument
  (`template IN AAAA cloudflarestorage.com`) if that ever becomes undesirable.
- If AAAA suppression is ever reverted, expect the Kopiur failures to return.

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
device — tailscale's 1280 — while `enp0s6` runs at 9000.

- **Why 1500, not 9000:** 1500 is the internet path MTU out of the OCI VCN, so pod egress never
  depends on path-MTU discovery. Nothing on this single node needs jumbo frames between pods.
- **`tailscale0` stays out of `devices` even though pod traffic now uses it.** Pod egress to the
  home LAN and Artemis pods reaches `tailscale0` through tailscale's policy table 52, without
  Cilium attached there — which is also what keeps that traffic unmasqueraded. Making it a Cilium
  device would put BPF masquerade on the tailnet path and hits an open tcx bug on it.
- **An MTU change only reaches existing pods when they are recreated.** The agent restart
  (needed on Frostlink because `rollOutCiliumPods` is false) moves the host-side `lxc*` interfaces, but
  each pod's own `eth0` keeps its old MTU until the pod is replaced. Check with
  `kubectl exec <pod> --context frostlink -- cat /sys/class/net/eth0/mtu`.

## cilium cluster identity: `id: 2`, `name: frostlink-vps`

Artemis is `id: 1`. Both values are left over from ClusterMesh (removed 2026-11-14), which needed
them unique. They stay because changing them re-identifies every endpoint for no gain.

- **Change the ID and the name together, never the ID alone.** The name is a pod identity label
  (`io.cilium.k8s.policy.cluster`); the ID is not. With an ID-only change the existing identities
  keep matching and Cilium reuses them, old numbers and all — restarting workloads does not help
  (Cilium maintainer, cilium/cilium#48801). Changing the name forces new identities.
- **No reboot.** Apply the values, then restart `deploy/cilium-operator` and `ds/cilium` by hand
  (`rollOutCiliumPods` is false). Every endpoint re-identifies on the agent restart; old
  identities are garbage-collected on their own.
- Verify the range: cluster N identities are `N*65536 … N*65536+65535`, so cluster 2 is
  `131072–196607`. `cilium-dbg endpoint list -o json` shows each endpoint's `identity.id`.

## The front door

Cloudflare Tunnel is gone. Public traffic reaches the node directly, and Envoy takes it.

- **Envoy owns public 80 and 443.** The towonel edge still binds host 443 and 80 (chart values),
  but a BPF path sends that traffic to Envoy, so the edge no longer receives it. Moving the edge
  off those ports is parked, because of the advertised-address risk.
- **Frostlink apps** are served by Envoy with their own HTTPRoutes.
- **Home (Artemis) apps** go over a private path. `towonel/home-backhaul` has Services
  `artemis-backhaul` and `artemis-backhaul-apex`, both pointing at the towonel pod on `:15001`.
  The Artemis agent publishes one TCP service, `artemis-backhaul`, on edge port 15001. It lands on
  Artemis `edge-gateway.network.svc.cluster.local:443`. HTTPRoutes `*.dcunha.io` and `dcunha.io`
  send traffic there.
- **Re-encryption.** BackendTLSPolicies check the Artemis certificate. SNI is `edge.dcunha.io`,
  and the apex Service uses SNI `dcunha.io` because Artemis `edge-gateway` has a separate apex
  listener.
- **When home is down**, a BackendTrafficPolicy runs a TCP health check with a 3 s connect timeout.
  A 502, 503 or 504 becomes the `home-down` ConfigMap page. Do not point the backhaul at
  Artemis `internal-gateway`: `edge-gateway` is the list of public Artemis apps.
- **Real client IPs.** Artemis `ClientTrafficPolicy/edge` trusts `X-Forwarded-For` from the agent
  pod CIDR, so its per-IP rate limits see real clients. Without it, everyone shares one limit.
  There is no PROXY protocol, no CrowdSec and no towonel hostname claim on Artemis now. Details:
  Artemis `.agents/references/towonel-agent.md`.

## Oracle Cloud VCN

Console-verified.

- **Security list ingress** (all stateful, all `0.0.0.0/0`, source port **All**,
  unless noted):
    - `443/tcp` — the front door: Envoy terminates TLS (Headscale passes through)
    - `80/tcp` — Envoy, for the HTTP→HTTPS redirect (`https-redirect` HTTPRoute).
      **Source port must be All** — a rule with source port `80` matches almost
      nothing, because clients send from an ephemeral port.
    - `51820/udp` — towonel iroh QUIC, where agents connect. **Missing the UDP half fails silently.**
    - `50000/tcp` — Talos API. Day-2 `talosconfig` points at `10.0.0.203` over the
      site link; this public rule is the break-glass when the tailnet is down, and the
      only way in during a rebuild (`oci-rebuild.md` § Rebuild order). Closing it removes
      both.
    - `6443/tcp` is **closed**, and is opened to your home /32 only for the length of a
      rebuild.
    - `22/tcp` — dead weight; Talos runs no SSH daemon
    - `icmp` 3,4 (path MTU) and `icmp` 3 from `10.0.0.0/16`
- **Deliberately closed**:
    - `8443/tcp` — the towonel hub API is bound on the host but speaks plain HTTP.
      It is reached through Envoy at `hub.frostlink.dev` instead. Opening this
      exposes the operator API in cleartext.
    - `6443/tcp` — removed. `kubeconfig` uses `10.0.0.203` over the
      Headscale site link, so the Kubernetes API never needed to be public.
- **Security list egress**: all allowed — this is what carries Tailscale, which is
  outbound-initiated and has no ingress rule of its own.

Stateless rules would break this: OCI skips connection tracking for any flow that
matches one, and a stateless rule takes precedence over a stateful one.

The node has its own second layer: a Talos ingress firewall that keeps every TCP port except
80/443/50000 internal-only (`oci-talos.md` § Host ingress firewall). Opening a port here is not enough on
its own; the Talos rule must allow it too.

### Egress budget alerts

`OciEgressBudgetHigh` (7 to 9 TB) and `OciEgressBudgetCritical` (over 9 TB) in
`observability/vm-alert/app/vmrule.yaml` watch `enp0s6` transmit bytes over **28d**, against the
10 TB Always Free allowance. `enp0s6` is the closest proxy for what Oracle bills; it over-counts,
which is the safe direction. The window is 28d, not 30d, because vm-single retains exactly 30d and
a `[30d]` range sits on the boundary where the oldest samples are expiring. The warning is bounded
(`> 7` and `<= 9`) so it hands off to the critical instead of both firing; an Alertmanager
`inhibit_rule` cannot do it because the two alertnames differ. Video through the front door is
what moves it, though the real ceiling is Artemis's residential upload.

## Access Methods

| Access type            | Method                                   | Address              |
| ---------------------- | ---------------------------------------- | -------------------- |
| Kubernetes API         | Headscale site link (from home)          | `10.0.0.203:6443`    |
| Talos API              | Headscale site link (from home)          | `10.0.0.203:50000`   |
| Talos API, break-glass | Public IP, while the OCI rule stays open | `40.233.88.33:50000` |

**How "from home" works:** your workstation (HME `10.10.1.0/24` or LAB `10.10.99.0/24`) sends to
`10.0.0.203` via its default gateway, the UCG Max. The UCG is a Headscale subnet router that
accepts Frostlink's advertised `10.0.0.203/32`, and the policy grants HME/LAB → `10.0.0.203/32`.
SNAT is off on both routers, so Frostlink sees the real LAN source. **Away from home**, a
Headscale device with subnet routes accepted (the iPhone) reaches `10.0.0.203` directly over the
tailnet. If Headscale itself is down, the public Talos port is the only break-glass.

## Tailnet policy — Headscale

Every device is on Headscale; no Tailscale SaaS tailnet remains. The policy is checked in at
`kube/clusters/frostlink/apps/network/headscale/app/resources/policy.hujson` and mounted into the Headscale pod
at `/etc/headscale/policy.hujson` — see § Headscale ingress for how the server is reached.
`kubectl --context frostlink -n network exec deploy/headscale -c app -- headscale nodes list`
shows the live devices (the node is `tag:frostlink`, the UCG Max `tag:home-router`, the rest user
`exikle`).

**The tailnet is for remote admin access** (Artemis #3082). Public traffic never uses it. The
policy was rewritten from scratch on 2026-11-14:

- Your own devices (`autogroup:member`) reach each other (`autogroup:self`), both routers, HME,
  LAB, the Frostlink node and the internet through the home exit node — and nothing else. A
  family device added to Headscale would land here too, so give it its own grant instead.
- HME → the Frostlink node allows only kubectl (6443) and talosctl (50000). That is the
  workstation's path; LAB has no reason to reach the node.
- Tagged devices (Frostlink, the home router) have no grants of their own: they answer, never
  initiate.
- Frostlink pods have no path to home. The `10.244.0.0/24` route and its grants were removed in
  #3297, after the status page moved to "home reports in" (`status-page.md`). A new Frostlink →
  home dependency goes through the front door, not the tailnet. The symptom of a pod that still
  tries the tailnet is a connection timeout, never an error.

The policy's `tests` block asserts the admin paths stay open and tagged devices stay shut.

Validate any policy edit with Headscale's own checker before committing. The running server can
check a file without loading it (the image has no shell, so pipe the file in):
`kubectl --context frostlink -n network exec -i deploy/headscale -c app -- headscale policy check -f /dev/stdin < policy.hujson`.
Two gotchas with the checker (0.29.7):

- **A failing test blocks only `policy check` and a SIGHUP reload.** A policy change reaches the
  pod as a ConfigMap update and Reloader restarts Headscale; at startup a failing test only logs a
  warning and the policy is applied anyway. Run the check before every apply.
- **The test engine ignores protocol.** A grant with `icmp:*` makes every TCP port to that
  destination test as ALLOWED; the real packet filter is not widened (verified from a pod). Do
  not write deny tests against a destination that has an `icmp:*` grant from the same source. A
  test `src` that is a member device's own LAN IP is treated as that device.

Existing tailnet connections survive a Headscale restart, but phones may briefly report the exit
node as down.

**DNS:** `override_local_dns: false`. Devices keep their own resolver for everything except
MagicDNS names and the split domains; the global `1.1.1.1`/`9.9.9.9` are a fallback only.

### Split DNS

`dns.nameservers.split` in the Headscale config sends `dcunha.io` to `10.10.99.1`, the UCG, the
same as the SaaS tailnet did. That is how `*.dcunha.io` names resolve on a device away from home.

- **The UCG's dnsmasq must listen on `tailscale0`.** UniFi generates an `interface=` list of LAN
  bridges with `bind-dynamic`, so a query arriving over the tailnet gets no answer: UDP is
  ignored and TCP is reset. Clients resolve via Tailscale's resolver, which forwards over the
  tailnet, so this breaks name resolution for every Headscale client, even at home. The fix is an
  `interface=tailscale0` drop-in, managed by Artemis's `ucg_tailscale` Ansible role.
- **Devices that never leave home keep `--accept-routes` off.** With it on, Windows prefers the
  tailnet route for HME/LAB over the directly connected network, so LAN traffic loops through the
  UCG. Arcana runs with it off. Split DNS and tailnet IPs still work without it.
- **Devices that roam keep it on.** The iPhone and grimoire (the Mac) need the routes away from
  home. macOS keeps its own connected subnet on `en0`, so at home on HME only LAB
  (`10.10.99.0/24`) and `10.0.0.203` go through the tailnet — a short hop to the UCG over the LAN
  (`route -n get 10.10.99.1` shows `utun`, `10.10.1.1` shows `en0`).

## Headscale ingress

`headscale.frostlink.dev` is a TLS passthrough on the front door. The `headscale` listener on
`external-gateway` (protocol `TLS`, mode `Passthrough`, same port 443) and a `TLSRoute` in the
Headscale HelmRelease send the raw stream to `headscale.network.svc.cluster.local:443`. The
listener only accepts routes from the `network` namespace.

- **Headscale terminates TLS itself**, with the `frostlink-dev-tls` wildcard mounted from
  `network`. It reads the certificate only at startup, so the Deployment carries
  `reloader.stakater.com/auto` — a cert-manager renewal rewrites the Secret and Reloader restarts
  the pod. Without that, Headscale serves the old certificate until it expires.
- **Envoy does not terminate it.** The Tailscale control protocol is an HTTP upgrade
  (`Upgrade: tailscale-control-protocol`) on a long-lived connection, so it must not go through
  Cloudflare or Envoy's HTTP path. That is why the route is a `TLSRoute` and the DNS record is a grey
  `DNSEndpoint` CNAME to `edge.frostlink.dev` (`network/headscale/app/dnsendpoint.yaml`).
- **Gateway-wide HTTP features do not apply to it.** CrowdSec and `response-hardening` work on
  HTTP, and a passthrough stream is not inspected.
- **The node's own tailscale logs in through this path.** If the front door is down, new tailnet
  logins fail; see `oci-rebuild.md` for why a rebuild cannot use it.
- **DERP is Tailscale's public map**, embedded DERP off. The embedded server needs public
  `3478/udp` for STUN, which is not open on OCI. Relayed traffic therefore crosses Tailscale Inc.'s
  DERP servers, still end-to-end WireGuard-encrypted.

`kube/clusters/frostlink/mise.toml` sets `KUBE_CONTEXT=frostlink` and every task in `kube/clusters/frostlink/mise.toml` passes it, so `mise run //kube/clusters/frostlink:<task>` targets Frostlink automatically. Bare `kubectl` needs `--context frostlink` (`tooling.md` § kubectl and talosctl scoping).

---
name: towonel-ops
description: Operate the towonel tunnel on Frostlink — check hub and edge health, issue or revoke an agent invite token, onboard a new origin/hostname, rotate the node's key material, or debug an agent that will not connect. Use for "towonel is down", "create a towonel invite", "add an agent", "expose X through towonel", "agent won't connect", "tunnel not routing", or "check the edge". Scoped to the Frostlink cluster.
compatibility: Requires the towonel hub and edge running in the `towonel` namespace, and 1Password access for key material. The edge is the main direct inbound path of Frostlink (80+443/tcp and 51820/udp, plus 25565/tcp and 3000/udp on demand; full list in oci-networking.md § Oracle Cloud VCN) — breaking it cuts external reachability, including Headscale.
---

# Skill: towonel Operations

Day-two operations for the towonel hub + edge running on Frostlink.

> Read `.agents/references/towonel.md` first — it carries the design decisions
> (why sqlite, why its own namespace, why 8443 is closed) that most of these
> commands assume.

## Step 1 — Confirm what is being asked

Ask before acting if it is not explicit:

- **Health check**, or **onboarding a new origin**, or **debugging a broken tunnel**?
- If onboarding: which **hostnames** should the agent be allowed to claim, and which
  machine runs the agent, and which TCP/UDP ports does it need? An invite is scoped to both.
- Onboarding a hostname under `frostlink.dev` also needs a DNS record pointing at
  `edge.frostlink.dev` (or the VPS IP) as **DNS-only**, not proxied.

## Step 2 — Health

The health, leader and session checks are `towonel.md` § Operating. In short: hub readiness is
`curl -s https://hub.frostlink.dev/v1/readyz`, `towonel_hub_is_leader` should be 1, and
`towonel_edge_active_sessions` should be 2 (Artemis plus the local `network/towonel-agent`); 0 or 1
is an outage. Metrics are only on the pod's own listeners (9091 hub, 9090 edge).

```bash
kubectl -n towonel get ds,pod,pvc --context frostlink
kubectl -n towonel logs ds/towonel --tail=50 --context frostlink
```

## Step 3 — Is the edge actually reachable?

```bash
dig +short edge.frostlink.dev @1.1.1.1     # MUST be 40.233.88.33, not 172.64.x.x
openssl s_client -connect 40.233.88.33:443 -servername <hostname> </dev/null
```

A `172.64.x.x` answer means the record went **proxied** and SNI routing is broken —
fix the `providerSpecific` override on the DNSEndpoint, do not annotate it.

With no matching agent, the edge accepts the ClientHello then closes with no
certificate. That is correct passthrough behaviour, not a fault.

UDP 51820 cannot be probed with TCP tools and **fails silently** when blocked. If
agents handshake over the relay but never go direct, suspect the UDP rule.

## Step 4 — Issuing an invite

The operator API key is generated on the node's data volume at `/data/operator.key`; the hub API
is `https://hub.frostlink.dev`. **Do not print the key.** Use it only as the credential to the
`towonel invite create` command, and see `towonel.md` § Operating for the exact grants.

**The invite carries port grants, not just hostnames.** A TCP/UDP service without a matching grant
leaves the edge declining to bind the listener, with no error on either side. The hostname list
and `tcp_ports`/`udp_ports` for the existing agents are in `towonel.md` § Operating.

The returned `tt_inv_2_<token>` is the only secret the agent needs. Store it in 1Password and pass
it as `TOWONEL_INVITE_TOKEN`; never commit it or paste it into a transcript.

## Step 5 — Adding a hostname to the tunnel

1. Issue (or extend) an invite covering the hostname and any ports.
2. Publish DNS for it pointing at the VPS, **DNS-only**. Follow the pattern in
   `kube/clusters/frostlink/apps/towonel/towonel/app/dnsendpoint.yaml`.
3. The origin keeps its own certificate — this is passthrough. It needs a cert valid
   for that hostname; on Artemis the `*.frostlink.dev` cert can be pulled from
   1Password (Frostlink pushes it via `network/certificates/export`).
4. Confirm `towonel_edge_active_sessions` rises and
   `towonel_edge_route_no_session_total` stays flat.

## Common Issues / Gotchas

- **Pod `Pending`, "did not have enough free storage"** — almost never real disk. See
  the CSINode topology-key gotcha in `.agents/references/openebs-zfs.md`.
- **PVC never binds** — the kopiur `Restore` is its populator; if the Restore is
  holding on `MissingRecordedIdentity` the PVC waits forever. See `towonel.md`.
- **Keys regenerated, every invite invalid** — the chart falls back to `emptyDir`
  unless `persistence.data.type` is set. Check
  `kubectl -n towonel get pod -o yaml --context frostlink | grep -A3 'name: data'` shows a
  `persistentVolumeClaim`, not `emptyDir`.
- **Backup refused, `PrivilegedMoverNotPermitted`** — the mover inherited
  `NET_BIND_SERVICE` from the edge. Patch the mover's security context; do **not**
  annotate the namespace for privileged movers.
- **`edge_link ... disabled` in the logs** — expected. Only relevant for remote edges.
- **Never open TCP 8443 on the OCI security list.** The hub speaks plain HTTP there.

## Backup and recovery

Key material and the sqlite hub DB live on the `towonel` PVC, backed up hourly by kopiur.
`mise run //kube/clusters/frostlink:snapshot-pvc towonel towonel` takes an on-demand snapshot (`towonel.md` § Operating).
Restore with the `kopiur-restore` skill; `mise run //kube/clusters/frostlink:restore-pvc` scales the workload down itself.
Losing `invite_hash.key` invalidates every outstanding invite, so confirm a snapshot exists before
anything that could destroy the volume.

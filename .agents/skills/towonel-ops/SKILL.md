---
name: towonel-ops
description: Operate the towonel tunnel on Frostlink — check hub and edge health, issue or revoke an agent invite token, onboard a new origin/hostname, rotate the node's key material, or debug an agent that will not connect. Use for "towonel is down", "create a towonel invite", "add an agent", "expose X through towonel", "agent won't connect", "tunnel not routing", or "check the edge". Scoped to the Frostlink cluster.
compatibility: Requires the towonel hub and edge running in the `towonel` namespace, and 1Password access for key material. The edge is the main direct inbound path of Frostlink (80+443/tcp and 51820/udp, plus 25565/tcp and 3000/udp on demand; full list in oci-networking.md § Oracle Cloud VCN) — breaking it cuts external reachability, including Headscale.
---

# Skill: towonel Operations

This skill covers day-two operations for the towonel hub and edge that run on Frostlink.

Read `.agents/references/towonel.md` first. It holds the design decisions that most of these
commands depend on: why sqlite, why its own namespace, and why 8443 is closed.

## Step 1 — Confirm what is being asked

If the request is not explicit, ask before you act:

1. Ask which task it is: a health check, onboarding a new origin, or debugging a broken tunnel.
2. If it is onboarding, ask which hostnames the agent can claim. Also ask which machine runs the
   agent and which TCP or UDP ports it needs. An invite is scoped to both the hostnames and the
   ports.
3. If the new hostname is under `frostlink.dev`, it also needs a DNS record. The record points at
   `edge.frostlink.dev` (or the VPS IP), and it must be DNS-only, not proxied.

## Step 2 — Health

`towonel.md` § Operating has the health, leader and session checks. In short:

- Hub readiness is `curl -s https://hub.frostlink.dev/v1/readyz`.
- `towonel_hub_is_leader` is 1 when healthy.
- `towonel_edge_active_sessions` is 1 when healthy (the Artemis agent). 0 is an outage.

The metrics are only on the pod's own listeners (9091 for the hub, 9090 for the edge).

```bash
kubectl -n towonel get ds,pod,pvc --context frostlink
kubectl -n towonel logs ds/towonel --tail=50 --context frostlink
```

## Step 3 — Is the edge actually reachable?

```bash
dig +short edge.frostlink.dev @1.1.1.1     # MUST be 40.233.88.33, not 172.64.x.x
openssl s_client -connect 40.233.88.33:443 -servername <hostname> </dev/null
```

A `172.64.x.x` answer means that the record became proxied, and SNI routing is broken. Fix the
`providerSpecific` override on the DNSEndpoint. Do not annotate the DNSEndpoint.

If no agent matches, the edge accepts the ClientHello and then closes the connection with no
certificate. That is correct passthrough behaviour, not a fault.

You cannot probe UDP 51820 with TCP tools. When a firewall blocks it, it fails silently. If agents
handshake over the relay but never connect directly, suspect the UDP rule.

## Step 4 — Issuing an invite

Run `mise run --yes //kube/clusters/frostlink:towonel-invite <agent> [--hostnames <h,...>] [--tcp-ports <p,...>]`.

The task reads the operator API key from `/data/operator.key` into memory. It never prints the key
or writes it to disk. `towonel.md` § Operating lists the grants that each agent needs.

The invite carries port grants as well as hostnames. If a TCP or UDP service has no matching grant,
the edge does not bind the listener, and neither side logs an error. `towonel.md` § Operating lists
the hostnames and the `tcp_ports`/`udp_ports` for the existing agents.

The returned `tt_inv_2_<token>` is the only secret that the agent needs. Store it in 1Password, and
pass it as `TOWONEL_INVITE_TOKEN`. Never commit it, and never paste it into a transcript.

## Step 5 — Adding a hostname to the tunnel

1. Issue an invite that covers the hostname and any ports, or extend an existing invite.
2. Publish a DNS record for the hostname that points at the VPS. The record must be DNS-only.
   Follow the pattern in `kube/clusters/frostlink/apps/towonel/towonel/app/dnsendpoint.yaml`.
3. Make sure that the origin has a certificate that is valid for that hostname. This is
   passthrough, so the origin keeps its own certificate. On Artemis, you can pull the
   `*.frostlink.dev` certificate from 1Password. Frostlink pushes it there through
   `network/certificates/export`.
4. Make sure that `towonel_edge_active_sessions` goes up and that
   `towonel_edge_route_no_session_total` stays flat.

## Common Issues / Gotchas

- Pod `Pending` with "did not have enough free storage": this is almost never a real disk problem.
  See the CSINode topology-key gotcha in `.agents/references/openebs-zfs.md`.
- PVC never binds: the kopiur `Restore` is the populator of the PVC. If the Restore holds on
  `MissingRecordedIdentity`, the PVC waits forever. See `towonel.md`.
- Keys regenerated, and every invite is invalid: the chart falls back to `emptyDir` unless
  `persistence.data.type` is set. Run
  `kubectl -n towonel get pod -o yaml --context frostlink | grep -A3 'name: data'`. Make sure that
  it shows a `persistentVolumeClaim`, not `emptyDir`.
- Backup refused with `PrivilegedMoverNotPermitted`: the mover inherited `NET_BIND_SERVICE` from
  the edge. Patch the security context of the mover. Do _not_ annotate the namespace for privileged
  movers.
- `edge_link ... disabled` in the logs: this is expected. It matters only for remote edges.
- Never open TCP 8443 on the OCI security list. The hub speaks plain HTTP on that port.

## Backup and recovery

The key material and the sqlite hub DB live on the `towonel` PVC. kopiur backs it up every hour.

- To take an on-demand snapshot, run `mise run //kube/clusters/frostlink:snapshot-pvc towonel towonel`
  (`towonel.md` § Operating).
- To restore, use the `kopiur-restore` skill. `mise run //kube/clusters/frostlink:restore-pvc`
  scales the workload down by itself.

If you lose `invite_hash.key`, every outstanding invite stops working. So before you do anything
that can destroy the volume, make sure that a snapshot exists.

---
name: towonel-ops
description: Operate the towonel tunnel on Frostlink — check hub and edge health, issue or revoke an agent invite token, onboard a new agent or backhaul port, rotate the node's key material, or debug an agent that will not connect. Use for "towonel is down", "create a towonel invite", "add an agent", "agent won't connect", "tunnel not routing", or "check the edge". Scoped to the Frostlink cluster.
compatibility: Requires the towonel hub and edge running in the `towonel` namespace, and 1Password access for key material. The edge carries the agent tunnels on 51820/udp and the Artemis backhaul on 15001/tcp. Public web traffic goes through Envoy, not the edge. Breaking the edge cuts every public site that Artemis serves (full port list in oci-networking.md § Oracle Cloud VCN).
---

# Skill: towonel Operations

This skill covers day-two operations for the towonel hub and edge that run on Frostlink. The edge
carries the Artemis agent tunnel (UDP 51820) and the TCP backhaul to Artemis (port 15001). Public
web traffic goes through Envoy, not through the edge.

Read `.agents/references/towonel.md` first. It holds the design decisions that most of these
commands depend on: why sqlite, why its own namespace, and why 8443 is closed. Where this skill and
`towonel.md` disagree, `towonel.md` wins.

## Step 1 — Confirm what is being asked

If the request is not explicit, ask before you act:

1. Ask which task it is: a health check, onboarding a new agent, or debugging a broken tunnel.
2. If it is onboarding, ask which machine runs the agent, and which TCP or UDP ports and hostnames
   it needs. An invite is scoped to both the hostnames and the ports.
3. If the request is to expose a public name, this skill does not apply. Public names go through
   Envoy on `edge-gateway` (`towonel-agent.md` § Which gateway a route uses).

## Step 2 — Health

`towonel.md` § Operating has the health, leader and session checks, and their healthy values. Start
with the workload:

```bash
kubectl -n towonel get ds,pod,pvc --context frostlink
kubectl -n towonel logs ds/towonel --tail=50 --context frostlink
```

## Step 3 — Is the edge actually reachable?

```bash
dig +short edge.frostlink.dev @1.1.1.1     # MUST be 40.233.88.33, not 172.64.x.x
kubectl -n towonel logs ds/towonel --tail=200 --context frostlink | grep 'agent session'
```

A `172.64.x.x` answer means that the record became proxied. The agent cannot reach the edge over
UDP through Cloudflare. Fix the `providerSpecific` override on the DNSEndpoint. Do not annotate the
DNSEndpoint (`towonel.md` § DNS must be grey-cloud, and the annotation does not work).

You cannot probe UDP 51820 with TCP tools. When a firewall blocks it, it fails silently. If agents
handshake over the relay but never connect directly, suspect the UDP rule.

## Step 4 — Issuing an invite

Run `mise run --yes //kube/clusters/frostlink:towonel-invite <agent> [--hostnames <h,...>] [--tcp-ports <p,...>]`.
The task asks first, so it needs `--yes`.

The task reads the operator API key from `/data/operator.key` into memory. It never prints the key
or writes it to disk. The grants that each agent needs, and why a missing port grant fails with no
error, are in `towonel.md` § Operating.

The returned `tt_inv_2_<token>` is the only secret that the agent needs. Store it in 1Password, and
pass it as `TOWONEL_INVITE_TOKEN`. Never commit it, and never paste it into a transcript.

## Step 5 — Adding a hostname to the tunnel

Do not add one. Artemis publishes no hostname through towonel today. Frostlink's Envoy terminates
public TLS and reaches Artemis over the backhaul. To publish a public service, follow
`towonel-agent.md` § Which gateway a route uses.

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
  the edge. Patch the security context of the mover. Do not annotate the namespace for privileged
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

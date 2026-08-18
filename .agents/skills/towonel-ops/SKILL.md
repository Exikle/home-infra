---
name: towonel-ops
description: Operate the towonel tunnel on Frostlink — check hub and edge health, issue or revoke an agent invite token, onboard a new origin/hostname, rotate the node's key material, or debug an agent that will not connect. Use for "towonel is down", "create a towonel invite", "add an agent", "expose X through towonel", "agent won't connect", "tunnel not routing", or "check the edge". Scoped to the Frostlink cluster.
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
  machine runs the agent? towonel scopes an invite to a hostname list.
- Onboarding a hostname under `frostlink.dev` also needs a DNS record pointing at
  `edge.frostlink.dev` (or the VPS IP) as **DNS-only**, not proxied.

## Step 2 — Health

```bash
kubectl -n towonel get ds,pod,pvc
kubectl -n towonel logs ds/towonel --tail=50

# hub control plane, through cloudflared
curl -s https://hub.frostlink.dev/v1/readyz          # => {"status":"ok"}
```

Metrics are only on the pod's own listeners (9091 hub, 9090 edge), not published:

```bash
kubectl -n towonel run q --rm -i --restart=Never --image=mirror.gcr.io/curlimages/curl \
  --command -- sh -c '
    curl -s http://towonel.towonel.svc.cluster.local:9091/metrics | grep towonel_hub_is_leader
    curl -s http://towonel.towonel.svc.cluster.local:9090/metrics | grep towonel_edge_active_sessions'
```

- `towonel_hub_is_leader 1` — the hub holds leadership. `0` means route rebuilds stall.
- `towonel_edge_active_sessions` — registered agents. **0 is correct until an agent exists.**

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

The operator API key is generated into the node's data volume:

```bash
kubectl -n towonel exec ds/towonel -- cat /data/operator.key
```

Invites are scoped to a hostname list and returned as a `tt_inv_2_<token>` string:

```bash
towonel invite create --name <agent> --hostnames '<host>,*.<host>'
```

The token is the **only** secret the agent needs — it carries tenant identity. Store
it in 1Password and pass it to the agent as `TOWONEL_INVITE_TOKEN`. Never commit it.

## Step 5 — Adding a hostname to the tunnel

1. Issue (or extend) an invite covering the hostname.
2. Publish DNS for it pointing at the VPS, **DNS-only**. Follow the pattern in
   `kubernetes/apps/towonel/towonel/app/dnsendpoint.yaml`.
3. The origin keeps its own certificate — this is passthrough. It needs a cert valid
   for that hostname; on Artemis the `*.frostlink.dev` cert can be pulled from
   1Password (Frostlink pushes it via `network/certificates/export`).
4. Confirm `towonel_edge_active_sessions` rises and
   `towonel_edge_route_no_session_total` stays flat.

## Common Issues / Gotchas

- **Pod `Pending`, "did not have enough free storage"** — almost never real disk. See
  the CSINode topology-key gotcha in `.agents/references/storage.md`.
- **PVC never binds** — the kopiur `Restore` is its populator; if the Restore is
  holding on `MissingRecordedIdentity` the PVC waits forever. See `towonel.md`.
- **Keys regenerated, every invite invalid** — the chart falls back to `emptyDir`
  unless `persistence.data.type` is set. Check
  `kubectl -n towonel get pod -o yaml | grep -A3 'name: data'` shows a
  `persistentVolumeClaim`, not `emptyDir`.
- **Backup refused, `PrivilegedMoverNotPermitted`** — the mover inherited
  `NET_BIND_SERVICE` from the edge. Patch the mover's security context; do **not**
  annotate the namespace for privileged movers.
- **`edge_link ... disabled` in the logs** — expected. Only relevant for remote edges.
- **Never open TCP 8443 on the OCI security list.** The hub speaks plain HTTP there.

## Backup and recovery

Key material (`node.key`, `hub_kek.key`, `invite_hash.key`) plus the sqlite hub DB
live on the `towonel` PVC, backed up hourly by kopiur to R2.

```bash
just kube backup towonel towonel                 # on-demand snapshot
just kube restore towonel towonel towonel        # DESTRUCTIVE — scale down first
```

Losing `invite_hash.key` invalidates every outstanding invite, so verify a snapshot
exists before any operation that could destroy the volume.

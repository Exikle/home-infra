# Reference: towonel — Frostlink

towonel is the private path between the public front door and Artemis. Frostlink runs the hub (the
control plane) and the edge. The Artemis agent connects to it over UDP 51820. Public web traffic
does _not_ go through the edge any more. Envoy owns the public ports 80 and 443 of the node
(`oci-networking.md` § The front door, issue #3082). The edge carries the agent tunnels and the
TCP backhaul to Artemis.

`towonel-agent.md` describes the agent side. The two files describe the two ends of one tunnel. If
they disagree about a port, a DNS record, or who terminates TLS, one of them is wrong. Frostlink no
longer runs an agent of its own.

Upstream: <https://codeberg.org/towonel/towonel> · charts `oci://codeberg.org/towonel/charts/`. The
node image is the chart default, `git.ow-ops.eu/towonel/towonel-node`. Look there for node updates.

## Shape here

One `towonel-node` release has both roles turned on. It runs in its own `towonel` namespace.

| Thing       | Value                                                |
| ----------- | ---------------------------------------------------- |
| Chart       | `oci://codeberg.org/towonel/charts/towonel-node`     |
| Namespace   | `towonel` (not `network`, see below)                 |
| Workload    | hostNetwork DaemonSet (a turned-on edge forces this) |
| Edge public | `edge.frostlink.dev` → `40.233.88.33`, DNS-only      |
| Hub API     | `hub.frostlink.dev` through Envoy                    |
| State       | sqlite on a PVC that kopiur backs up                 |

The hub and the edge share one process. A single node has nowhere to put a separate edge. The split
exists only to run edges in other regions.

- `TOWONEL_HUB_PUBLIC_URL` is where agents reach the control plane. That path goes through Envoy,
  not the raw 8443 listener.
- `TOWONEL_EDGE_ADVERTISED_ADDRESSES` is where agents connect to the edge. It must be the DNS-only
  A record.
- The edge's `/data` needs only the key files and the sqlite DB. So the 1Gi `KOPIUR_CAPACITY` is
  more than enough.
- The public IP of the node in `FROSTLINK_PUBLIC_IP` is not a secret.

### The backhaul to Artemis

`kube/clusters/frostlink/apps/towonel/home-backhaul` holds the Frostlink half of the backhaul.
`oci-networking.md` § The front door says what it holds and how it works, and it wins. The
Artemis half is in `towonel-agent.md`.

For the edge, one fact matters: Envoy terminates the public TLS, then encrypts again to Artemis.
So the edge never sees plaintext, and it does no SNI routing for public names.

## Why its own namespace

The edge is a hostNetwork DaemonSet that binds host `:443` and `:80`. PodSecurity `baseline`
forbids both host namespaces and hostPorts. `network` has no PSS label, so it inherits `baseline`.
A privileged label on `network` also relaxes envoy-gateway and external-dns. So
towonel gets its own namespace at `pod-security.kubernetes.io/enforce: privileged`. This is the
same pattern as `cert-manager`, `observability` and `openebs-system`.

## Why the hub API is not exposed directly

The hub speaks plain HTTP on `:8443`, unless `TOWONEL_HUB_TLS_ACME_EMAIL` is set. That TLS path is
ACME TLS-ALPN-01. Let's Encrypt validates TLS-ALPN-01 only on port 443, and Envoy owns port 443.
There is no option for a static certificate. `hub_tls_cert_dir` is ACME `FileStorage`, not a place
for an existing certificate.

So the hub is published as an `HTTPRoute` on `external-gateway`. There, Envoy terminates TLS with
the existing `*.frostlink.dev` certificate.

TCP 8443 must stay closed on the OCI security list. hostNetwork binds it on the host. So an open
rule exposes the operator API in cleartext. This file owns that rule. `oci-networking.md` § Oracle
Cloud VCN links here.

## Why sqlite and not the CNPG cluster

The hub supports `postgres`, but the team chose sqlite for these reasons:

- If the tunnel control plane depends on Postgres, a Renovate bump of the CNPG image can take
  ingress down. That failure already broke the mautrix bridges (see `database.md` § Why clients
  must tolerate a primary change).
- The Postgres advisory lock matters only for a hub with several replicas for HA. A single node
  cannot have that.
- The node already needs a persistent volume for its keys. So sqlite adds no new state to back up.

## The data volume is not optional

`/data` holds three keys:

- `node.key`: the edge identity.
- `hub_kek.key`: seals the hub signing keys.
- `invite_hash.key`.

If you lose `invite_hash.key`, every outstanding invite stops working.

The chart's `templates/_config.tpl` forces the volume to `emptyDir` unless you set
`persistence.data.type` explicitly. The chart silently ignores `existingClaim` on its own, and the
keys then regenerate on every restart. Always set both:

```yaml
persistence:
    data:
        type: persistentVolumeClaim
        existingClaim: towonel
```

Do not add `globalMounts`/`advancedMounts`. The chart already mounts the volume at `edge.dataDir`,
and a second mount mounts the volume twice.

## kopiur movers need an explicit security context

Both patches live in `kube/clusters/frostlink/apps/towonel/towonel/app/kustomization.yaml`. The
component is pulled in _there_, not through `components:` in the Flux Kustomization. Patches in
the app kustomization do not apply to resources that a Flux `spec.components` adds.

| Mover   | Component default                        | Why it fails                                                                                                                                           |
| ------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Restore | `inheritSecurityContextFrom.snapshot`    | A first deploy has no recorded snapshot → `MissingRecordedIdentity`. The Restore holds, and the PVC never binds, because the Restore is its populator. |
| Backup  | `inheritSecurityContextFrom.pvcConsumer` | It inherits `NET_BIND_SERVICE` from the edge. kopiur treats any added capability as a privileged mover and refuses it (`PrivilegedMoverNotPermitted`). |

Both movers are patched to a plain non-root context (uid/gid `10001`, the same as the chart). The
namespace is not annotated for privileged movers.

Target the patches by kind, not by name. `postBuild` substitution runs after kustomize, so at patch
time the resources are still literally named `${KOPIUR_APP}`.

## DNS must be grey-cloud, and the annotation does not work

`edge.frostlink.dev` must be a grey A record to the node (`towonel/app/dnsendpoint.yaml`). Agents
connect to it, so a proxied record breaks the tunnel. The DNS rules (grey records,
`providerSpecific`, the `dig` test, the shared zone) are in `oci-networking.md` § DNS, which wins.

## Ports

There are two kinds of port:

- Static ports. The DaemonSet declares them and holds them for its whole life.
- Dynamic ports. The edge binds them on demand when an agent registers a TCP or UDP service.

### Static — declared on the DaemonSet

| Port      | Proto | Where            | Open on OCI?                                               |
| --------- | ----- | ---------------- | ---------------------------------------------------------- |
| 443       | TCP   | edge TLS (SNI)   | open, but Envoy gets the traffic (BPF). The edge sees none |
| 51820     | UDP   | iroh QUIC        | yes. Agents connect here                                   |
| 8443      | TCP   | hub API          | no. Traffic goes through Envoy                             |
| 80        | TCP   | edge HTTP        | open, but Envoy gets the traffic. The edge sees none       |
| 51444     | TCP   | hub↔edge link    | no. Single pod, turned off                                 |
| 9090/9091 | TCP   | edge/hub metrics | no. Scraped in-cluster                                     |

The edge still binds host 443 and 80 (chart values). A move off these ports needs a change to the
advertised address, and that change is the risk. This file owns that fact.

The UDP 51820 rule on OCI: `oci-networking.md` § Oracle Cloud VCN, which wins.

### Dynamic — bound per agent service

The edge binds one port for each agent TCP or UDP service while a session exists. Today that is
`15001/tcp` for `artemis-backhaul`. This port is _not_ open on the OCI security list. Only the
Frostlink pod reaches it, in-cluster (the `towonel` Service, `home-backhaul`). These listeners are
not in `kubectl get ds -n towonel towonel -o yaml --context frostlink`. The edge logs them:

```text
edge tcp listener bound   port=15001 service=artemis-backhaul
```

The listeners exist only while the agent session exists. So if the agent is down, a probe of the
port proves nothing. The invite must grant the port (§ Operating).

## Monitoring

The chart ships hub alerts and a ServiceMonitor. vm-operator converts them into `VMRule` and
`VMServiceScrape`. The chart has no edge alerts. The team took them from `eleboucher/homelab` and
put them in `app/prometheusrule-edge.yaml`. They removed the upstream `cluster="towonel-ops"`
selector, which exists only because that hub runs outside its cluster.

Leave `TowonelEdgeNoSessions` on. Agents now exist, so zero sessions is not a valid steady state.
A dead tunnel takes every `dcunha.io` name down behind the `home-down` page. This alert is the one
that tells you why. The `for: 10m` lets an agent rollout finish without a false alert.

## Operating

```bash
# health
kubectl -n towonel logs ds/towonel --tail=50 --context frostlink
curl -s https://hub.frostlink.dev/v1/readyz            # {"status":"ok"}

# is the hub the active leader (should be 1), and how many agents are attached (should be 1 —
# the Artemis agent; 0 is an outage)
kubectl -n towonel run q --rm -i --restart=Never --context frostlink --image=mirror.gcr.io/curlimages/curl \
  --command -- sh -c '
    curl -s http://towonel.towonel.svc.cluster.local:9091/metrics | grep towonel_hub_is_leader
    curl -s http://towonel.towonel.svc.cluster.local:9090/metrics | grep towonel_edge_active_sessions'

# agent sessions, from the logs
kubectl -n towonel logs ds/towonel --tail=200 --context frostlink | grep 'agent session'

# on-demand backup of the key material
mise run //kube/clusters/frostlink:snapshot-pvc towonel towonel
```

This section owns the invite procedure. `towonel-agent.md` links here.

To create an invite, you use the operator API key. The node generates that key into `/data`
(`/data/operator.key`). Never print it. The task below reads the key into memory and never writes
it to disk. It posts to the hub API at `https://hub.frostlink.dev`. The hub returns the invite as
a `tt_inv_2_<token>` string:

```bash
mise run --yes //kube/clusters/frostlink:towonel-invite <agent> [--hostnames '<host>,*.<host>'] [--tcp-ports <port>,...]
```

The invite carries the port grants and the hostname claims. Both flags are optional. The Artemis
agent claims no hostnames. It publishes one TCP service (`artemis-backhaul`, port 15001, in its
`towonel-agent/app/helmrelease.yaml`). So its invite needs only `--tcp-ports 15001`. If an agent
service has no matching grant, the edge does not bind the listener, and neither side logs an
error.

## Gotchas

- `helm show chart oci://codeberg.org/towonel/charts/towonel` returns 404. The chart is
  `towonel-node` (hub, edge, or both).
- The probes that the chart derives use `timeoutSeconds: 1`. A short Postgres gap killed the
  mautrix bridges with that same tight setting. The HelmRelease sets looser values. Do not let a
  chart bump silently reset them.
- Two startup log lines are harmless:
    - `edge_link listen_addr and psk must both be set; edge_link disabled`. That link matters only
      for remote edges.
    - `Insecure TLS config: server certificates will be trusted without verification`
      (`iroh_relay::tls`). This is the default of the relay client, not the public TLS path of
      towonel.

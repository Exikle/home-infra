# Frostlink node

Frostlink is one machine. Every fact on this page carries weight, so the page is not an inventory.

## The node

- Shape: VM.Standard.A1.Flex, 4 OCPU, 24 GB RAM, ARM64 Ampere A1.
- Block volumes: a 50 GB boot volume (10 VPU, `sda`) and a separate 107 GB block volume (`sdb`).
  `sdb` holds the whole `openebs` ZFS pool. If you lose `sdb`, you lose every PVC that has no R2
  backup. To read the disks, run
  `talosctl --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 get discoveredvolumes`.
- Location: ca-toronto-1 AD-1, instance `instance-20260612-2239`.
- Public address: `40.233.88.33` (reserved). Internal address: `10.0.0.203`. The internal address
  is the management address. You reach it over the Headscale site link.
- Extensions: `iscsi-tools`, `tailscale`, `util-linux-tools`, `zfs`. Do not remove `zfs`. The whole
  `openebs-zfs` storage layer depends on it.
- Live versions are a command, not a number:
  `talosctl version --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203` and
  `kubectl version --context frostlink`. The talosconfig names no node, so every `talosctl` call
  needs `-n 10.0.0.203`.

Management access is over the Headscale site link (`oci-networking.md` § Access Methods). The tool
calls of an agent do not get the cluster kubeconfig, so always pass `--context frostlink`. The VCN,
the DNS records, the ingress set of the security list and the front door are in
`oci-networking.md`.

## Namespaces

`ls kube/clusters/frostlink/apps/` is the live list. The table keeps only the purpose column,
because no command recovers it.

| Namespace          | Purpose                                                                       |
| ------------------ | ----------------------------------------------------------------------------- |
| `cert-manager`     | ACME issuer, CSI driver, internal Postgres CA, trust bundles                  |
| `cnpg-system`      | Postgres operator and its backup plugin                                       |
| `database`         | The shared Postgres cluster, its pooler, and the shared Dragonfly             |
| `default`          | Empty by design. Nothing is deployed here                                     |
| `dragonfly-system` | Dragonfly operator                                                            |
| `external-secrets` | Secret sync from 1Password                                                    |
| `fediverse`        | Fediverse server, web client and registry                                     |
| `flux-system`      | Flux controllers and the root Kustomization                                   |
| `kopiur-system`    | PVC backup controller and the `r2` ClusterRepository (Cloudflare R2)          |
| `kube-system`      | CNI, DNS and cluster plumbing                                                 |
| `matrix`           | Matrix homeserver and its bridges                                             |
| `network`          | Front door (Envoy, CrowdSec bouncer), certificates, Cloudflare DNS, Headscale |
| `observability`    | Metrics, alerting, status page                                                |
| `openebs-system`   | zfs-localpv CSI. Provides the default `openebs-zfs` StorageClass              |
| `system-upgrade`   | Talos and Kubernetes upgrade controller (tuppr)                               |
| `towonel`          | Tunnel hub and edge, in its own `privileged` namespace for `hostNetwork`      |

## Known quirks

Each of these cost real time to find. The full text is in the linked doc.

- OCI DNS: only `169.254.169.254` works as the CoreDNS upstream. See `oci-rebuild.md` § OCI DNS —
  CoreDNS Forward Target.
- Cilium needs `sysctlfix.enabled: false` on Talos. See `oci-talos.md` § Known OCI / Talos Quirks.
- Helm v4 SSA conflicts (`helm-controller` field manager): cilium, coredns and cert-manager install
  with a direct `helm upgrade --install`. See `oci-rebuild.md` § Cilium / CoreDNS / cert-manager —
  Install Directly.
- Do not use `helmfile --cleanup-on-fail`. On failure, it deletes cluster-scoped resources. It also
  leaves orphaned SSA ownership that conflicts on the next try.
- `talosctl patch machineconfig --patch` takes a delta, never a full configuration. See
  `oci-talos.md` § Config Management.
- Forgejo is HTTPS-only, because SSH is not reachable from OCI. The `flux-system/flux-system` secret
  is an apoci pull placeholder, not a Git credential. See `oci-rebuild.md` § Flux flux-system
  Secret.
- PodSecurity and hostNetwork: `network` stays `baseline`. towonel has its own namespace. See
  `towonel.md` § Why its own namespace.
- Stale CSINode topology keys can stop every new PVC from scheduling. See `openebs-zfs.md`
  § Gotcha: stale CSINode topology keys block every new PVC.
- flate resolves `dependsOn` by `targetNamespace`, so a cross-namespace reference needs
  `namespace:`. See `flux-patterns.md` § Cross-Namespace Kustomization Gotchas.

# Frostlink node

Frostlink is one machine. Its facts are load-bearing, so they are not inventory.

## The node

- **VM.Standard.A1.Flex**: 4 OCPU, 24 GB RAM, ARM64 Ampere A1, 50 GB boot volume (10 VPU).
- **ca-toronto-1 AD-1**, instance `instance-20260612-2239`.
- **Public** `40.233.88.33` (reserved). **Internal** `10.0.0.203`: the management address, reached over the Headscale site link.
- **Extensions**: `iscsi-tools`, `tailscale`, `util-linux-tools`, `zfs`. **`zfs` is load-bearing.** The whole `openebs-zfs` storage layer depends on it.
- Live versions are a command, not a number: `talosctl version --talosconfig kube/clusters/frostlink/talosconfig` and `kubectl version --context frostlink`.

Management access is over the Headscale site link (`oci-networking.md` § Access Methods). An agent's
tool calls do not get the cluster kubeconfig, so always pass `--context frostlink`. The VCN, DNS
records, the security-list ingress set and the front door are in `oci-networking.md`.

## Namespaces

`ls kube/clusters/frostlink/apps/` is the live list. The table keeps only the purpose column,
which no command recovers.

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

- **OCI DNS**: only `169.254.169.254` works as CoreDNS upstream. `oci-rebuild.md` § OCI DNS — CoreDNS Forward Target.
- **Cilium `sysctlfix.enabled: false`** is required on Talos. `oci-talos.md` § Known OCI / Talos Quirks.
- **Helm v4 SSA conflicts** (`helm-controller` field manager): cilium, coredns and cert-manager install with a direct `helm upgrade --install`. `oci-rebuild.md` § Cilium / CoreDNS / cert-manager — Install Directly.
- **`helmfile --cleanup-on-fail`** deletes cluster-scoped resources on failure and leaves orphaned SSA ownership that conflicts on retry. Do not use it.
- **`talosctl patch machineconfig --patch` takes a delta**, never a full config. `oci-talos.md` § Config Management.
- **Forgejo is HTTPS-only** (SSH is unreachable from OCI). The `flux-system/flux-system` secret is an apoci pull placeholder, not a Git credential. `oci-rebuild.md` § Flux flux-system Secret.
- **PodSecurity + hostNetwork**: `network` stays `baseline`. towonel has its own namespace. `towonel.md` § Why its own namespace.
- **Stale CSINode topology keys** can leave no new PVC schedulable. `openebs-zfs.md` § Gotcha: stale CSINode topology keys block every new PVC.
- **flate resolves `dependsOn` by `targetNamespace`**, so cross-namespace refs need `namespace:`. `flux-patterns.md` § Cross-Namespace Kustomization Gotchas.

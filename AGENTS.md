# Frostlink — Agent Context

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free Ampere A1 (ca-toronto-1), managed with Flux CD.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecrets (no SOPS)
- **Domain**: `frostlink.dev` | **Repo**: <https://git.dcunha.io/Exikle/frostlink>
- **CNI**: Cilium | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

---

## Repo Structure

```text
.agents/          # AI agent instructions, references, and skills
talos/            # Talos schematic and patches
kubernetes/
  apps/           # App HelmReleases by namespace
  flux/sync/      # Entrypoint Kustomization → kubernetes/apps
```

---

## Hardware

### Frostlink Node (Oracle Cloud)

- **VM.Standard.A1.Flex** — 4 OCPU / 24 GB RAM, ARM64 Ampere A1
- **Boot volume**: 50 GB / 10 VPU
- **Region**: ca-toronto-1, AD-1
- **Image**: Talos Linux (UEFI, paravirtualized networking, QEMU guest agent)
- **Schematic**: `e4c2f7fe09fbcc3e03227a77dcb705e0e8b76acc3ef9f0e43f39f7723c8c98bc`

---

## Networking

- **VCN**: `frostlink-vcn`, subnet `frostlink-public` (10.0.0.0/24)
- **Public IP**: reserved IP → frostlink.dev A record
- **Security list ingress**: 50000/tcp + 6443/tcp from home IP only; 80/443 from 0.0.0.0/0
- **DNS**: Cloudflare (frostlink.dev zone), managed by external-dns

---

## Namespaces & Apps

| Namespace          | Key Apps                                          |
| ------------------ | ------------------------------------------------- |
| `flux-system`      | flux-operator, flux-instance                      |
| `kube-system`      | Cilium, local-path-provisioner                    |
| `cert-manager`     | cert-manager + Cloudflare DNS01 ClusterIssuer     |
| `network`          | Envoy Gateway, external-dns                       |
| `external-secrets` | External Secrets Operator (1Password)             |
| `apoci`            | apoci OCI registry (federation peer for Artemis)  |
| `headscale`        | Headscale VPN control plane                       |
| `monitoring`       | Gatus / Uptime Kuma                               |

---

## Bootstrap Order

1. Import Talos custom image (Oracle Compute → Custom Images, QCOW2, PARAVIRTUALIZED, UEFI_64)
2. Launch VM.Standard.A1.Flex (4 OCPU / 24 GB, frostlink-vcn, boot vol 50 GB)
3. Attach reserved public IP; create frostlink.dev A record
4. `talosctl gen config frostlink https://<reserved-ip>:6443 --config-patch @talos/patches/controlplane.yaml`
5. `talosctl apply-config --insecure -n <ip> --file controlplane.yaml`
6. `talosctl bootstrap -n <ip>`
7. `flux bootstrap git --url=https://git.dcunha.io/Exikle/frostlink.git --branch=main --path=kubernetes/flux/sync`
8. Apply infra in order: external-secrets → cert-manager → network → apps

---

## Known Quirks

- Single node — control plane also acts as worker (`allowSchedulingOnControlPlanes: true` in `talos/patches/controlplane.yaml`)
- Oracle Cloud paravirtualized NIC — Talos detects it automatically; no manual interface config needed
- Forgejo reachability from Oracle: HTTPS via git.dcunha.io (Cloudflare Tunnel) — SSH not available; `flux bootstrap` must use HTTPS

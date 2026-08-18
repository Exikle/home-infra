# Frostlink — Agent Context

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free Ampere A1 (ca-toronto-1), managed with Flux CD.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecrets (no SOPS)
- **Domain**: `frostlink.dev` | **Repo**: <https://git.dcunha.io/Exikle/frostlink>
- **CNI**: Cilium | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute via Cloudflare tunnel)

---

## Repo Structure

```text
.agents/          # AI agent instructions, references, and skills
talos/            # Talos schematic and patches
bootstrap/        # helmfile.d/ and resources.yaml.j2 for one-time bootstrap
kubernetes/
  apps/           # App HelmReleases by namespace
  components/     # Reusable Flux Components (postgres/cert, kopiur, anubis, alerts)
  flux/sync/      # Entrypoint Kustomization → kubernetes/apps
```

---

## Hardware

### Frostlink Node (Oracle Cloud)

- **VM.Standard.A1.Flex** — 4 OCPU / 24 GB RAM, ARM64 Ampere A1
- **Boot volume**: 50 GB / 10 VPU
- **Region**: ca-toronto-1, AD-1
- **Instance name**: `instance-20260612-2239`
- **Public IP**: `40.233.88.33` (reserved, frostlink.dev A record)
- **Internal IP**: `10.0.0.203`
- **Tailscale IP**: `100.67.108.103`
- **Talos version**: v1.13.4 | **Kubernetes**: v1.36.1
- **Schematic**: `e4c2f7fe09fbcc3e03227a77dcb705e0e8b76acc3ef9f0e43f39f7723c8c98bc`
- **Extensions**: iscsi-tools, util-linux-tools, qemu-guest-agent, tailscale

---

## Networking

- **VCN**: `frostlink-vcn`, subnet `frostlink-public` (10.0.0.0/24)
- **Public IP**: `40.233.88.33` reserved → frostlink.dev A record
- **Tailscale**: node joined (tag: k8s); management access via `100.67.108.103`
- **OCI DNS**: node resolver is `169.254.169.254` (OCI metadata link-local) — CoreDNS must forward there, NOT `/etc/resolv.conf` which resolves to unreachable `127.0.0.53`
- **Security list ingress**: 50000/tcp + 6443/tcp from home IP; 80/443 from 0.0.0.0/0
- **kubeconfig**: `~/.kube/config` on WSL, context `frostlink`, server `https://100.67.108.103:6443`

---

## Namespaces & Apps

| Namespace          | Key Apps                                          | Status     |
| ------------------ | ------------------------------------------------- | ---------- |
| `kube-system`      | Cilium 1.17.4, CoreDNS 1.46.0                     | ✓ deployed |
| `cert-manager`     | cert-manager 1.20.3                               | ✓ deployed |
| `external-secrets` | External Secrets 2.7.0, 1Password Connect 2.4.1   | ✓ deployed |
| `flux-system`      | flux-operator 0.53.0, flux-instance (Flux v2.8.8) | ✓ deployed |
| `network`          | Envoy Gateway, wildcard cert, cloudflare-tunnel   | ✓ deployed |
| `fediverse`        | GoToSocial, phanpy, apoci (OCI registry)          | ✓ deployed |
| `matrix`           | continuwuity, mautrix-signal, mautrix-whatsapp    | ✓ deployed |
| `database`         | shared CNPG Postgres + pooler, shared Dragonfly   | ✓ deployed |
| `observability`    | VictoriaMetrics, alertmanager, kromgo, gatus      | ✓ deployed |

---

## Bootstrap Order

Bootstrap uses helmfile (not `flux bootstrap`) because the Forgejo repo must already have content before Flux GitRepository can sync. See `.agents/references/bootstrap.md` for full detail.

1. Import Talos custom image → launch VM.Standard.A1.Flex (4 OCPU / 24 GB, 50 GB boot)
2. Attach reserved public IP; ensure security list allows 50000/tcp
3. `talosctl gen config` with patches → `talosctl apply-config --insecure` → `talosctl bootstrap`
4. Export kubeconfig: `talosctl kubeconfig`
5. Apply bootstrap secrets: `KUBECONFIG=... just bootstrap base`
   - Requires 1Password items: `1password-frostlink`, `forgejo-frostlink`, `cloudflare-frostlink`
6. Run `just bootstrap cni` — installs cilium, coredns, cert-manager directly via `helm upgrade --install` (NOT via helmfile — SSA conflict); reads chart/version/values straight from each app's `ocirepository.yaml`/`helmrelease.yaml`
7. Run `just bootstrap apps` — installs external-secrets → onepassword-connect → flux-operator → flux-instance
8. Commit and push repo to Forgejo → Flux reconciles everything from Git
9. Deploy `network` namespace **first** (cert-manager clusterissuer → envoy-gateway → certificates → cloudflare-tunnel) before any app with an HTTPRoute

---

## Known Quirks

- **Single node**: control plane also acts as worker (`allowSchedulingOnControlPlanes: true`)
- **OCI DNS**: `169.254.169.254` is the only working upstream for CoreDNS. `/etc/resolv.conf` resolves to `127.0.0.53` (unreachable inside pods). Set `forward . 169.254.169.254` in CoreDNS values.
- **Cilium on Talos/OCI**: must set `sysctlfix.enabled: false` — Talos has no `/etc/sysctl.d/`; cilium-agent init crashes otherwise.
- **Helm v4 SSA conflicts**: Talos pre-installs cilium and coredns with field manager `helm-controller`. Helmfile also uses `helm-controller`. `just bootstrap cni` installs cilium, coredns, and cert-manager with direct `helm upgrade --install` calls to avoid conflicts.
- **`helmfile --cleanup-on-fail`**: deletes cluster-scoped resources on failure, leaving orphaned SSA ownership that conflicts on retry.
- **`talosctl patch machineconfig --patch`**: expects a DELTA patch (only changed fields). Passing a full config duplicates array fields (e.g. `machine.files`) and breaks the node on next boot. Use a minimal patch file, or `talosctl apply-config --file` for full replacement.
- **Forgejo auth via HTTPS**: SSH unreachable from OCI. Flux uses HTTPS with secret `flux-system/flux-system` (`username` + `password` fields).
- **certSANs for Tailscale**: apply with a 6-line minimal patch — never include the full `controlplane.yaml` as a patch.
- **flate `dependsOn` namespace**: `just kube apply-ks` uses flate, which resolves dependencies by `targetNamespace`. Cross-namespace refs require `namespace: <targetNamespace>` (e.g. `namespace: cert-manager` for clusterissuer, `namespace: external-secrets` for onepassword-connect). Without it, flate looks in the current ks's own targetNamespace and fails.

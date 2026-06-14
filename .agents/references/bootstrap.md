# Bootstrap Reference — Frostlink

Details for bootstrapping the frostlink cluster from scratch.

## 1Password Items Required

| Item name              | Fields used                                          |
| ---------------------- | ---------------------------------------------------- |
| `1password-frostlink`  | `OP_CREDENTIALS_JSON`, `OP_CONNECT_TOKEN`            |
| `forgejo-frostlink`    | `username` (exikle), `token` (Forgejo access token)  |
| `cloudflare-frostlink` | `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_TUNNEL_TOKEN`    |

## bootstrap/resources.yaml.j2

Creates the following secrets before Flux and ExternalSecrets are running:

- `external-secrets/onepassword-connect-credentials-secret` — 1Password Connect credentials JSON
- `external-secrets/onepassword-connect-vault-secret` — 1Password Connect token
- `flux-system/flux-system` — Forgejo HTTPS auth (username + password/token)
- `network/cloudflare-tunnel-id-secret` — Cloudflare tunnel ID

Apply with: `KUBECONFIG=/path/to/kubeconfig just bootstrap base`

## Cilium / CoreDNS / cert-manager — Install Directly

These three are NOT in `bootstrap/helmfile.d/01-apps.yaml`. Install them manually before running helmfile:

**Why**: Talos pre-installs Cilium and CoreDNS using field manager `helm-controller`. Helmfile v4 also uses `helm-controller`. Applying both results in SSA ownership conflicts. cert-manager's `startupapicheck` Job also conflicts. Install all three with direct `helm install` calls instead.

**Cilium** — must set `sysctlfix.enabled: false` (Talos has no `/etc/sysctl.d/`):
```bash
helm install cilium cilium/cilium --namespace kube-system --version 1.17.4 \
  --set sysctlfix.enabled=false \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=127.0.0.1 \
  --set k8sServicePort=7445 \
  --set kubeProxyReplacement=true \
  --set operator.replicas=1
```

**CoreDNS** — must forward to `169.254.169.254` (not `/etc/resolv.conf`):
```bash
helm install coredns coredns/coredns --namespace kube-system \
  --set fullnameOverride=coredns \
  --set k8sAppLabelOverride=kube-dns \
  --set "service.clusterIP=10.96.0.10" \
  --set "service.name=kube-dns"
# then apply helmrelease values via --values file with forward . 169.254.169.254
```

**cert-manager**:
```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 --set crds.enabled=true \
  --timeout 5m --wait
```

## OCI DNS — CoreDNS Forward Target

`talosctl get resolvers` on the node shows `["169.254.169.254"]`.

`/etc/resolv.conf` on the node contains `nameserver 127.0.0.53` (systemd-resolved stub). This address is unreachable inside pods. CoreDNS must use `forward . 169.254.169.254` — not the default `/etc/resolv.conf`.

## Flux flux-system Secret

Flux GitRepository needs `flux-system/flux-system` secret to authenticate to the private Forgejo repo:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: flux-system
  namespace: flux-system
type: Opaque
stringData:
  username: exikle
  password: <forgejo-token>
```

This is created by `just bootstrap base` via `resources.yaml.j2` (references `op://kubernetes/forgejo-frostlink/token`).

## certSANs — Tailscale IP

To reach the API via Tailscale, apply a minimal patch (never pass the full `controlplane.yaml` as a patch — it duplicates `machine.files` and breaks the node):

```yaml
# /tmp/certsans-patch.yaml
machine:
  certSANs:
    - 100.67.108.103
cluster:
  apiServer:
    certSANs:
      - 100.67.108.103
```

```bash
talosctl patch machineconfig --nodes <ip> --patch @/tmp/certsans-patch.yaml
```

Then update kubeconfig server: `kubectl config set-cluster frostlink --server=https://100.67.108.103:6443`

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

These three are NOT in `bootstrap/helmfile.d/01-apps.yaml`. `just bootstrap cni` (wired into `phase2` between `base` and `apps`) installs all three directly via `helm upgrade --install`, one per iteration, reading `chart`/`version` from each app's `ocirepository.yaml` and `values` from its `helmrelease.yaml` — so the bootstrap-time install always matches whatever is currently checked in, with nothing hardcoded to go stale.

**Why not helmfile**: Talos pre-installs Cilium and CoreDNS using field manager `helm-controller`. Helmfile v4 also uses `helm-controller`. Applying both results in SSA ownership conflicts. cert-manager's `startupapicheck` Job also conflicts. Install all three with direct `helm` CLI calls instead — its default field manager (`helm`) avoids the collision.

**Important**: `cluster.network.cni.name: none`, `cluster.coreDNS.disabled: true`, and `machine.kubelet.disableManifestsDirectory: true` are all set in `talos/patches/controlplane.yaml`. Together these stop Talos from ever applying its own CNI/CoreDNS/flannel bootstrap manifests, so there's nothing to clean up manually before Cilium and CoreDNS take over.

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

## Post-Bootstrap App Deployment Order

Deploy the `network` namespace **before any app that has an HTTPRoute**. Apps with `web.httpRoute.enabled: true` (e.g. flux-operator) will create an HTTPRoute but traffic cannot flow until envoy-gateway and cloudflare-tunnel are running.

Correct order after Flux is reconciling:

1. `cert-manager/clusterissuer` — ExternalSecret + ClusterIssuer (dependsOn: cert-manager, onepassword-connect)
2. `network/envoy-gateway` — Envoy Gateway + GatewayClass + external-gateway (ClusterIP)
3. `network/certificates` — wildcard cert `frostlink.dev` / `*.frostlink.dev` (dependsOn: clusterissuer)
4. `network/cloudflare-tunnel` — routes `*.frostlink.dev` to envoy internally (dependsOn: envoy-gateway, certificates)
5. All other apps with HTTPRoutes (any order)

**flate dependsOn namespace rule**: `just kube apply-ks` uses `flate` which resolves `dependsOn` by `targetNamespace`, not `flux-system`. Cross-namespace dependencies require an explicit `namespace:` field matching the dependency's `targetNamespace`:

```yaml
dependsOn:
  - name: clusterissuer
    namespace: cert-manager   # matches clusterissuer ks targetNamespace
  - name: onepassword-connect
    namespace: external-secrets
```

Without `namespace:`, flate looks in the current kustomization's own `targetNamespace` and fails with "dependency not found".

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

# Bootstrap Reference — Frostlink

Rebuilding the cluster from nothing. **Status: operational, not historical** — every recipe named
here still exists in `bootstrap/mod.just` and was re-checked against it on 2026-08-21. But the
cluster has been up since 2026-06-13, so nothing on this page is exercised in normal work: treat
it as a disaster-recovery runbook, and re-read `bootstrap/mod.just` before running any of it
rather than trusting the summaries here.

One thing it is genuinely historical about, and the reason a rebuild is not a clean replay: the
Tailscale auth key is injected into the node's config at gen time and **never persisted to the
repo**, so the running node's full machine config cannot be regenerated from git. See
`.agents/references/talos.md` § CRITICAL: never `apply-config` the patch file.

## The two phases

```bash
export FROSTLINK_INIT_IP=<OCI public IP>     # required by phase1
just bootstrap phase1                        # config + apply — reboots the node
# wait for the node to appear in the Tailscale admin console
export FROSTLINK_NODE_IP=<Tailscale IP>      # phase2 defaults to FROSTLINK_INIT_IP if unset
just bootstrap phase2                        # k8s + kubeconfig + base + cni + apps
```

Both are `[confirm]`-gated. The sub-recipes are `[private]` — `phase1` is `config apply`, and
`phase2` is `k8s kubeconfig base cni apps`, run in that order. `just bootstrap base` and friends
can still be invoked individually for a partial redo.

| Recipe | What it does |
| ------------ | -------------------------------------------------------------------------------- |
| `config` | `talosctl gen config` with `talos/patches/controlplane.yaml` + a generated certSANs patch, into `/tmp/frostlink-bootstrap`, then **appends the Tailscale `ExtensionServiceConfig`** with `TS_AUTHKEY` read from `op://kubernetes/tailscale-frostlink/TS_AUTH_KEY` |
| `apply` | `talosctl apply-config --insecure` against `FROSTLINK_INIT_IP` |
| `k8s` | `talosctl bootstrap`, retried until it reports `AlreadyExists` |
| `kubeconfig` | `talosctl kubeconfig --force-context-name frostlink` into the repo root |
| `base` | namespaces → bootstrap secrets → CRDs from `bootstrap/helmfile.d/00-crds.yaml` |
| `cni` | cilium, coredns, cert-manager via direct `helm upgrade --install` |
| `apps` | `helmfile -f bootstrap/helmfile.d/01-apps.yaml sync` |

`FROSTLINK_NODE_IP` defaults to `FROSTLINK_INIT_IP`. Leaving it unset means phase2 talks to the
node over its **public** IP — it works, but 6443/tcp was removed from the OCI security list on
2026-08-18, so set it to the Tailscale IP.

## 1Password Items Required

| Item name              | Fields used                                          |
| ---------------------- | ---------------------------------------------------- |
| `1password-frostlink`  | `OP_CREDENTIALS_JSON`, `OP_CONNECT_TOKEN`            |
| `forgejo-frostlink`    | `username` (exikle), `token` (Forgejo access token)  |
| `cloudflare-frostlink` | `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_TUNNEL_TOKEN`    |
| `tailscale-frostlink`  | `TS_AUTH_KEY` — read by `config`, not by `base`      |

## bootstrap/resources.yaml.j2

Creates the following secrets before Flux and ExternalSecrets are running:

- `external-secrets/onepassword-connect-credentials-secret` — 1Password Connect credentials JSON
- `external-secrets/onepassword-connect-vault-secret` — 1Password Connect token
- `flux-system/flux-system` — Forgejo HTTPS auth (username + password/token)
- `network/cloudflare-tunnel-id-secret` — Cloudflare tunnel ID

Applied by `just bootstrap base`, which also creates every namespace under `kubernetes/apps/`
first and applies the CRDs from `bootstrap/helmfile.d/00-crds.yaml` afterwards. Inside this repo
`.mise.toml` already pins `KUBECONFIG`, so no `KUBECONFIG=` prefix is needed — but during a real
bootstrap the repo-root `kubeconfig` does not exist until `just bootstrap kubeconfig` has run.

## Cilium / CoreDNS / cert-manager — Install Directly

These three are NOT in `bootstrap/helmfile.d/01-apps.yaml`. `just bootstrap cni` (wired into `phase2` between `base` and `apps`) installs all three directly via `helm upgrade --install`, one per iteration, reading `chart`/`version` from each app's `ocirepository.yaml` and `values` from its `helmrelease.yaml` — so the bootstrap-time install always matches whatever is currently checked in, with nothing hardcoded to go stale.

**Why not helmfile**: Talos pre-installs Cilium and CoreDNS using field manager `helm-controller`. Helmfile v4 also uses `helm-controller`. Applying both results in SSA ownership conflicts. cert-manager's `startupapicheck` Job also conflicts. Install all three with direct `helm` CLI calls instead — its default field manager (`helm`) avoids the collision.

**Important**: `cluster.network.cni.name: none`, `cluster.coreDNS.disabled: true`, and `machine.kubelet.disableManifestsDirectory: true` are all set in `talos/patches/controlplane.yaml`. Together these stop Talos from ever applying its own CNI/CoreDNS/flannel bootstrap manifests, so there's nothing to clean up manually before Cilium and CoreDNS take over.

## OCI DNS — CoreDNS Forward Target

`talosctl get resolvers` on the node shows `["169.254.169.254"]`.

`/etc/resolv.conf` on the node contains `nameserver 127.0.0.53` (systemd-resolved stub). This address is unreachable inside pods. CoreDNS must use `forward . 169.254.169.254` — not the default `/etc/resolv.conf`.

## Flux flux-system Secret

**Not a Git credential.** The Flux source is an **OCIRepository**, not a GitRepository —
`FluxInstance/flux` syncs `oci://registry.frostlink.dev/exikle/frostlink` (Forgejo's container
registry) and names this same secret as its `sync.pullSecret`. The Forgejo username/token happen
to authenticate both the repo and its registry, which is why one secret covers it. There is no
`GitRepository` object in the cluster; see `.agents/references/flux-patterns.md`.

The secret is `Opaque` with `username` + `password` keys:

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
mise exec -- talosctl patch machineconfig --nodes <ip> \
  --patch-file /tmp/certsans-patch.yaml --dry-run   # read the diff, then re-run without --dry-run
```

Always `--dry-run` first — it prints the exact config diff and whether a reboot is required, and
the diff **includes the Tailscale auth key**, so do not paste it anywhere. Use `mise exec --` so
the pinned talosctl (matching the cluster's Talos version) is the one that decodes the documents.

Then update kubeconfig server: `kubectl config set-cluster frostlink --server=https://100.67.108.103:6443`

## After Flux is up — do not sync early

The OCI artifact is built by CI from the pushed commit. Syncing the `flux-system` OCIRepository
before that build goes green re-resolves the **pre-commit** digest and silently applies old state.
This applies during bootstrap as much as during normal work — see
`.agents/references/flux-patterns.md` § There is no `GitRepository`.

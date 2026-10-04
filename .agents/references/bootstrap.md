# Bootstrap Reference — Frostlink

Rebuilding the cluster from nothing. **Status: operational, not historical** — every recipe named
here still exists in `bootstrap/mod.just` and was re-checked against it on 2026-08-21. But the
cluster has been up since 2026-06-13, so nothing on this page is exercised in normal work: treat
it as a disaster-recovery runbook, and re-read `bootstrap/mod.just` before running any of it
rather than trusting the summaries here.

## Two circles a rebuild has to break (frostlink#347)

1. **The tailnet runs on this cluster.** The node's tailscale logs into Headscale, which is a
   Frostlink app. A rebuild therefore reaches the node **only over its public IP**: Talos API on
   `40.233.88.33:50000` (open on OCI), and the Kubernetes API on 6443 — which is **closed** on OCI
   and must be opened to your home /32 for the duration. The node joins Headscale last, with a
   freshly minted key (`just bootstrap tailnet`).
2. **The Flux source runs on this cluster.** `registry.frostlink.dev` is apoci on Frostlink, and
   since 2026-10-04 every `*.dcunha.io` name (Forgejo, Artemis's apoci) is served through
   Frostlink's towonel edge. Nothing at home is reachable from a rebuilding node. So the **first**
   artifact comes from your PC: `just bootstrap seed` pulls CI's copy from Forgejo
   (`oci://git.dcunha.io/exikle/frostlink:main`) over the home network and pushes it into a
   throwaway in-cluster registry (`bootstrap/seed-registry.yaml`). The bootstrap FluxInstance syncs
   from that over plain HTTP (`helmfile.d/templates/flux-instance-seed.yaml.gotmpl`). Flux then
   upgrades `flux-instance` to its real source — and the `flux-instance` Kustomization
   `dependsOn` apoci and cloudflare-tunnel, so that switch waits until `registry.frostlink.dev`
   can actually answer.

The running node's tailscale key lives only in its machine config, never in the repo — see
`.agents/references/talos.md` § CRITICAL: never `apply-config` the patch file.

## Rebuild order

```bash
export FROSTLINK_INIT_IP=40.233.88.33
just bootstrap phase1        # gen config + apply over public 50000 — no tailscale config; reboots
# OCI console: add ingress 6443/tcp from <home public IP>/32 (stateful)
just bootstrap phase2        # k8s, kubeconfig, talosconfig, base, cni, seed, apps — all over the public IP
```

Then, in order:

1. **Watch Flux reconcile from the seed.** `kubectl -n flux-system get ocirepository flux-system`
   shows the `seed-registry` URL until `flux-instance` switches it to `registry.frostlink.dev`.
2. **Check every kopiur restore pulled a real snapshot** before trusting the apps —
   `kubectl get restore -A`. The component uses `onMissingSnapshot: Continue`, so a wrong R2
   credential or repository yields an **empty volume, not an error**. For Headscale that means a
   new noise key and an empty database: every device would have to re-register.
3. **Check Headscale came back with its devices:** `kubectl -n network exec deploy/headscale -c app
-- headscale nodes list` shows the UCG and your devices; the UCG reconnects on its own.
4. `just bootstrap tailnet` — mints a one-hour, one-time `tag:frostlink` key, substitutes it into
   `talos/patches/tailscale.yaml.j2` in a 600 temp file, and patches it onto the node over the
   public Talos API (no reboot). The key is never written to 1Password; it is spent on first use.
5. **Delete the old frostlink node** it prints (`headscale nodes delete -i <id>`), and confirm the
   new one shows routes `10.0.0.203/32` and `10.244.0.0/24` approved
   (`headscale nodes list-routes`) — the policy auto-approves them for `tag:frostlink`.
6. **Switch to the site link:** `kubectl config set-cluster frostlink --server=https://10.0.0.203:6443`
   and `talosctl config endpoint 10.0.0.203` (the repo-root `talosconfig` was written with the
   public IP by phase2). Verify both, then **remove the OCI 6443 rule**. Leave 50000 as the
   break-glass.
7. `kubectl delete -f bootstrap/seed-registry.yaml` — the seed registry is not Flux-managed.
8. ClusterMesh with Artemis rides the tailnet, so it reconnects only after step 4.

**Not yet proven by a real rebuild:** Headscale registering the new machine key and re-approving
its routes; kopiur's restore waiting for the repository instead of racing to an empty volume; the
towonel hub restore still accepting the agent invite (Headscale ingress rides on it). Check each
as you go.

Recipes (all `[private]` except the three entry points):

| Recipe         | What it does                                                                                                                       |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `config`       | `talosctl gen config` with `talos/patches/controlplane.yaml` + a certSANs patch for the public IP, into `/tmp/frostlink-bootstrap` |
| `apply`        | `talosctl apply-config --insecure` against `FROSTLINK_INIT_IP`                                                                     |
| `k8s`          | `talosctl bootstrap`, retried until it reports `AlreadyExists`                                                                     |
| `kubeconfig`   | `talosctl kubeconfig --force-context-name frostlink` into the repo root                                                            |
| `talosconfig`  | installs the rebuild talosconfig at the repo root (endpoint = public IP)                                                           |
| `base`         | namespaces → bootstrap secrets → CRDs from `bootstrap/helmfile.d/00-crds.yaml`                                                     |
| `cni`          | cilium, coredns, cert-manager via direct `helm upgrade --install`                                                                  |
| `seed`         | seed registry up, `flux pull artifact` from Forgejo, `flux push artifact --insecure-registry` into it                              |
| `apps`         | `helmfile -f bootstrap/helmfile.d/01-apps.yaml sync`                                                                               |
| `tailnet-join` | the `tailnet` entry point's body — mint key, render, `talosctl patch mc`                                                           |

No certSAN step is needed for `10.0.0.203` or any tailnet IP: Talos adds the node's own addresses
to the apiserver certificate automatically (checked against the served cert 2026-10-04).

## 1Password Items Required

All live in the `frostlink` vault except where noted.

| Item name              | Fields used                                                       |
| ---------------------- | ----------------------------------------------------------------- |
| `1password`            | `OP_CREDENTIALS_JSON`                                             |
| `access-token`         | `credential` — the Connect server access token                    |
| `forgejo-frostlink`    | `username` (exikle), `token` (Forgejo access token)               |
| `cloudflare-frostlink` | `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_TUNNEL_TOKEN`                 |
| `artemis/forgejo`      | `FORGEJO_PAT` — `seed` pulls the CI artifact from Forgejo with it |

The tailnet key is minted fresh by `just bootstrap tailnet`; no 1Password item is read for it. The
old SaaS item `tailscale` is unused and goes once the SaaS account closes (frostlink#348).

Two items keep the `-frostlink` suffix deliberately, for opposite reasons:

- `cloudflare-frostlink` — **Artemis reads it** for frostlink's DNS and certificates. Artemis's
  own `cloudflare` item would outrank a renamed one in its vault priority, so the distinct name
  is the only way to express the cross-read.
- `forgejo-frostlink` — **this cluster reads Artemis's `forgejo`** by the bare name, for
  `FORGEJO_ADMIN_TOKEN` (see `konflate-webhook-token`). A frostlink item named `forgejo` sits at
  priority 1 and shadows it.

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
`FluxInstance/flux` syncs `oci://registry.frostlink.dev/exikle/frostlink` (apoci on this cluster —
CI pushes there and to Forgejo's registry) and names this same secret as its `sync.pullSecret`. The Forgejo username/token happen
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

This is created by `just bootstrap base` via `resources.yaml.j2` (references `op://frostlink/forgejo-frostlink/token`).

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
      namespace: cert-manager # matches clusterissuer ks targetNamespace
    - name: onepassword-connect
      namespace: external-secrets
```

Without `namespace:`, flate looks in the current kustomization's own `targetNamespace` and fails with "dependency not found".

## After Flux is up — do not sync early

The OCI artifact is built by CI from the pushed commit. Syncing the `flux-system` OCIRepository
before that build goes green re-resolves the **pre-commit** digest and silently applies old state.
This applies during bootstrap as much as during normal work — see
`.agents/references/flux-patterns.md` § There is no `GitRepository`.

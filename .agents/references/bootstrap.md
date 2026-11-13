# Bootstrap Reference — Frostlink

Rebuilding the cluster from nothing. Nothing on this page is exercised in normal work: treat it as
a disaster-recovery runbook, and re-read `bootstrap/mod.just` (`just --list bootstrap`) before
running any of it rather than trusting the summaries here.

## Two circles a rebuild has to break (frostlink#347)

1. **The tailnet runs on this cluster.** The node's tailscale logs into Headscale, which is a
   Frostlink app. A rebuild therefore reaches the node **only over its public IP**: Talos API on
   `40.233.88.33:50000` (open on OCI), and the Kubernetes API on 6443 — which is **closed** on OCI
   and must be opened to your home /32 for the duration. The node joins Headscale last, with a
   freshly minted key (`just bootstrap tailnet`).
2. **The Flux source runs on this cluster.** `registry.frostlink.dev` is apoci on Frostlink, and
   every `*.dcunha.io` name (Forgejo, Artemis's apoci) is served through Frostlink's Envoy
   and the towonel backhaul to Artemis. Nothing at home is reachable from a rebuilding node. So the **first**
   artifact comes from your PC: `just bootstrap seed` pulls CI's copy from Forgejo
   (`oci://git.dcunha.io/exikle/frostlink:main`) over the home network and pushes it into a
   throwaway in-cluster registry (`bootstrap/seed-registry.yaml`). The bootstrap FluxInstance syncs
   from that over plain HTTP (`helmfile.d/templates/flux-instance-seed.yaml.gotmpl`). Flux then
   upgrades `flux-instance` to its real source — and the `flux-instance` Kustomization
   `dependsOn` apoci and envoy-gateway, so that switch waits until `registry.frostlink.dev`
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

1. **Watch Flux reconcile from the seed.** `kubectl get ocirepository flux-system -n flux-system
   --context frostlink` shows the `seed-registry` URL until `flux-instance` switches it to
   `registry.frostlink.dev`.
2. **Check every kopiur restore pulled a real snapshot** before trusting the apps —
   `kubectl get restore -A --context frostlink`. The component uses `onMissingSnapshot: Continue`,
   so a wrong R2 credential or repository yields an **empty volume, not an error**. For Headscale that means a
   new noise key and an empty database: every device would have to re-register.
3. **Check Headscale came back with its devices:** `kubectl exec deploy/headscale -n network -c app
   --context frostlink -- headscale nodes list` shows the UCG and your devices; the UCG reconnects
   on its own.
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
7. `kubectl delete -f bootstrap/seed-registry.yaml --context frostlink` — the seed registry is not Flux-managed.
8. ClusterMesh with Artemis rides the tailnet, so it reconnects only after step 4.

**Not yet proven by a real rebuild:** Headscale registering the new machine key and re-approving
its routes; kopiur's restore waiting for the repository instead of racing to an empty volume; the
towonel hub restore still accepting the agent invite (Headscale ingress rides on it). Check each
as you go.

Recipes: `phase1`, `phase2` and `tailnet` are the entry points; the rest are `[private]` steps
(`config apply k8s kubeconfig talosconfig base cni seed apps tailnet-join`) — `just --list
bootstrap` and `bootstrap/mod.just` say what each does.

No certSAN step is needed for `10.0.0.203` or any tailnet IP: Talos adds the node's own addresses
to the apiserver certificate automatically (checked against the served cert).

## 1Password Items Required

`grep -rn 'op://' bootstrap` lists them. Two naming rules have no other home:

- `cloudflare-frostlink` keeps its suffix deliberately: **Artemis reads it** for frostlink's DNS and
  certificates. Artemis's own `cloudflare` item would outrank a renamed one in its vault priority, so
  the distinct name is the only way to express the cross-read.
- Never create a frostlink item named `forgejo`: both clusters read `infrastructure/forgejo` by the
  bare name, and a frostlink one would sit at priority 1 and shadow it.

The tailnet key is minted fresh by `just bootstrap tailnet`, and the Flux pull secret needs no item
(apoci serves pulls anonymously and ignores the credentials, so `resources.yaml.j2` writes a fixed
placeholder).

## bootstrap/resources.yaml.j2

Creates the following secrets before Flux and ExternalSecrets are running:

- `external-secrets/onepassword-connect-credentials-secret` — 1Password Connect credentials JSON
- `external-secrets/onepassword-connect-vault-secret` — 1Password Connect token
- `flux-system/flux-system` — Forgejo HTTPS auth (username + password/token)
- `network/cloudflare-tunnel-id-secret` — Cloudflare tunnel ID (the tunnel is retired; this secret
  and the `bootstrap/` steps that create it need a rewrite)

Applied by `just bootstrap base`, which also creates every namespace under `kubernetes/apps/`
first and applies the CRDs from `bootstrap/helmfile.d/00-crds.yaml` afterwards. During a real
bootstrap the repo-root `kubeconfig` does not exist until `just bootstrap kubeconfig` has run.

## Cilium / CoreDNS / cert-manager — Install Directly

These three are NOT in `bootstrap/helmfile.d/01-apps.yaml`. `just bootstrap cni` (wired into `phase2` between `base` and `apps`) installs all three directly via `helm upgrade --install`, one per iteration, reading `chart`/`version` from each app's `ocirepository.yaml` and `values` from its `helmrelease.yaml` — so the bootstrap-time install always matches whatever is currently checked in, with nothing hardcoded to go stale.

**Why not helmfile**: Talos pre-installs Cilium and CoreDNS using field manager `helm-controller`, and
Helmfile v4 uses the same one, so applying both gives SSA ownership conflicts (cert-manager's
`startupapicheck` Job conflicts too). Direct `helm` CLI calls use the default field manager
(`helm`) and avoid the collision. Never add `--cleanup-on-fail` to a helmfile release: on failure
it deletes cluster-scoped resources and leaves orphaned SSA ownership that then conflicts on retry.

Talos itself never applies its own CNI, CoreDNS or kube-proxy manifests, because
`talos/patches/controlplane.yaml` disables them with typed documents (`KubeFlannelCNIConfig`
`$patch: delete`, `KubeCoreDNSConfig` and `KubeProxyConfig` `enabled: false`), so there is nothing
to clean up before Cilium and CoreDNS take over.

## OCI DNS — CoreDNS Forward Target

`talosctl get resolvers --talosconfig /home/exikle/frostlink/talosconfig` on the node shows `["169.254.169.254"]`.

`/etc/resolv.conf` on the node contains `nameserver 127.0.0.53` (systemd-resolved stub). This address is unreachable inside pods. CoreDNS must use `forward . 169.254.169.254` — not the default `/etc/resolv.conf`.

## Flux flux-system Secret

**Not a Git credential.** The Flux source is an **OCIRepository**, not a GitRepository —
`FluxInstance/flux` syncs `oci://registry.frostlink.dev/exikle/frostlink` (apoci on this cluster —
CI pushes there and to Forgejo's registry) and names this same secret as its `sync.pullSecret`.
There is no `GitRepository` object in the cluster; see `flux-patterns.md`.

The secret `flux-system/flux-system` is `Opaque` with `username` + `password` keys.
`just bootstrap base` creates it via `resources.yaml.j2` as a fixed placeholder; apoci ignores it.
Flux itself never authenticates to Forgejo. Anything that does reach Forgejo uses HTTPS, because
SSH is unreachable from OCI.

## Post-Bootstrap App Deployment Order

Deploy the `network` namespace **before any app that has an HTTPRoute**: the route is created, but
traffic cannot flow until envoy-gateway is running. This order is **not**
encoded in `dependsOn` (envoy-gateway depends only on cert-manager),
so follow it by hand once Flux is reconciling. **This list needs a rewrite for the front door:**
the tunnel step is gone, and Envoy now owns the node's public 80 and 443 (`networking.md` §
The front door).

1. `cert-manager/clusterissuer`
2. `network/envoy-gateway` (Envoy Gateway, GatewayClass, external-gateway)
3. `network/certificates` (wildcard `frostlink.dev` / `*.frostlink.dev`)
4. All other apps with HTTPRoutes, any order

A cross-namespace `dependsOn` ref needs an explicit `namespace:` (`flux-patterns.md` § flate
`dependsOn` Namespace).

## After Flux is up — do not sync early

Syncing the `flux-system` OCIRepository before CI has built the artifact re-resolves the
**pre-commit** digest and silently applies old state — during bootstrap as much as in normal work
(`flux-patterns.md` § There is no `GitRepository`).

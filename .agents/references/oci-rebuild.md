# Frostlink rebuild from nothing

This page rebuilds Frostlink from nothing. For Artemis, read `bootstrap.md`. Normal work never runs
anything on this page. Treat it as a disaster-recovery runbook. Before you run any of it, read
`kube/clusters/frostlink/bootstrap/mise.toml` again (`mise tasks ls --all`). Do not trust the
summaries here.

## Two circles a rebuild has to break

1. The tailnet runs on Frostlink. The tailscale of the node logs into Headscale, and Headscale is a
   Frostlink app. So a rebuild reaches the node only over its public IP. The Talos API is on
   `40.233.88.33:50000`, which is open on OCI. The Kubernetes API is on 6443, which is closed on
   OCI. You must open 6443 to your home /32 for the length of the rebuild. The node joins Headscale
   last, with a new key (`mise run //kube/clusters/frostlink/bootstrap:tailnet`).
2. The Flux source runs on Frostlink. `registry.frostlink.dev` is apoci on Frostlink. Every
   `*.dcunha.io` name (Forgejo, the apoci of Artemis) goes through the Envoy of Frostlink and the
   towonel backhaul to Artemis. A rebuilding node cannot reach anything at home. So the first
   artifact comes from your PC. `mise run //kube/clusters/frostlink/bootstrap:seed` pulls the CI
   copy from Forgejo (`oci://git.dcunha.io/exikle/frostlink:main`) over the home network. It pushes
   the copy into a temporary in-cluster registry (`kube/clusters/frostlink/bootstrap/seed-registry.yaml`).
   The bootstrap FluxInstance syncs from that registry over plain HTTP
   (`helmfile.d/templates/flux-instance-seed.yaml.gotmpl`). Flux then upgrades `flux-instance` to
   its real source. The `flux-instance` Kustomization waits on `flux-instance-extras`, and
   `flux-instance-extras` has `dependsOn` on apoci and envoy-gateway. So the switch waits until
   `registry.frostlink.dev` can answer.

The tailscale key of the running node lives only in its machine configuration, never in git. See
`oci-talos.md` § CRITICAL: never `apply-config` the patch file.

## Rebuild order

```bash
export FROSTLINK_INIT_IP=40.233.88.33
mise run //kube/clusters/frostlink/bootstrap:phase1        # gen config + apply over public 50000 — no tailscale config; reboots
# OCI console: add ingress 6443/tcp from <home public IP>/32 (stateful)
mise run //kube/clusters/frostlink/bootstrap:phase2        # k8s, kubeconfig, talosconfig, base, cni, seed, apps — all over the public IP
```

Then do these steps in order:

1. Watch Flux reconcile from the seed.
   `kubectl get ocirepository flux-system -n flux-system --context frostlink` shows the
   `seed-registry` URL until `flux-instance` switches it to `registry.frostlink.dev`.
2. Before you trust the apps, make sure that every kopiur restore pulled a real snapshot. The
   component uses `onMissingSnapshot: Continue`. So a wrong R2 credential or repository gives an
   empty volume, not an error. `phase` reads `Completed` for an empty restore too, so read the
   resolution:

    ```bash
    kubectl get restore -A --context frostlink -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RES:.status.resolved.resolution
    ```

    Every row must read `Snapshot`. `NoSnapshot` means an empty volume. Stop, and read
    `openebs-zfs.md` § Restore. For Headscale, an empty volume means a new noise key and an empty
    database. Every device then has to register again.

3. Make sure that Headscale came back with its devices.
   `kubectl exec deploy/headscale -n network -c app --context frostlink -- headscale nodes list`
   shows the UCG and your devices. The UCG connects again on its own.
4. Run `mise run //kube/clusters/frostlink/bootstrap:tailnet`. It makes a one-hour, one-time
   `tag:frostlink` key. It puts the key into `kube/clusters/frostlink/talos/patches/tailscale.yaml.j2`
   in a temporary file with mode 600. It patches the result onto the node over the public Talos
   API, with no reboot. The key is never written to 1Password. The first use spends it.
5. Delete the old frostlink node that the task prints (`headscale nodes delete -i <id>`). Make sure
   that the new node shows the route `10.0.0.203/32` as approved (`headscale nodes list-routes`).
   The policy approves it automatically for `tag:frostlink`.
6. Switch to the site link. phase2 wrote `kube/clusters/frostlink/kubeconfig` and
   `kube/clusters/frostlink/talosconfig` with the public IP. Run these three commands from the
   repo root:

    ```bash
    kubectl --kubeconfig kube/clusters/frostlink/kubeconfig config set-cluster frostlink --server=https://10.0.0.203:6443
    talosctl --talosconfig kube/clusters/frostlink/talosconfig config endpoint 10.0.0.203
    talosctl --talosconfig kube/clusters/frostlink/talosconfig config node 10.0.0.203
    ```

    Make sure that both work.

7. Remove the OCI 6443 rule. Leave 50000 open as the break-glass path.
8. Apply the host firewall over the site link (`oci-talos.md` § Host ingress firewall). Do not
   apply it earlier. It blocks the public 6443 path that this rebuild used.
9. Run `kubectl delete -f kube/clusters/frostlink/bootstrap/seed-registry.yaml --context frostlink`.
   Flux does not manage the seed registry.

A real rebuild did not yet prove these three things. Make sure of each one as you go:

- Headscale registers the new machine key and approves its routes again.
- The kopiur restore waits for the repository, and does not race to an empty volume.
- The towonel hub restore still accepts the agent invite. Headscale ingress depends on it.

No step in this runbook creates or imports the `openebs` ZFS pool on the block volume `sdb`
(`oci-node.md` § The node). The procedure for a rebuild that keeps or replaces `sdb` is not
written down ([#3383](https://git.dcunha.io/Exikle/home-infra/issues/3383)).

Tasks: `phase1`, `phase2` and `tailnet` are the entry points. The other tasks are hidden steps
(`config apply k8s kubeconfig talosconfig base cni seed apps tailnet-join`).
`mise tasks ls --all --hidden` and `kube/clusters/frostlink/bootstrap/mise.toml` say what each one
does.

You do not need a certSAN step for `10.0.0.203` or for any tailnet IP. Talos adds the addresses of
the node to the apiserver certificate automatically. This was compared against the served
certificate.

## 1Password Items Required

`grep -rn 'op://' kube/clusters/frostlink/bootstrap` lists them. Two naming rules are written
nowhere else:

- `cloudflare-frostlink` keeps its suffix on purpose, because Artemis reads it for the DNS and the
  certificates of frostlink. The own `cloudflare` item of Artemis has a higher vault priority than a
  renamed item. So the separate name is the only way to express the cross-read.
- Never create a frostlink item named `forgejo`. Both clusters read `infrastructure/forgejo` by the
  bare name. A frostlink item gets priority 1 and hides it.

`mise run //kube/clusters/frostlink/bootstrap:tailnet` makes the tailnet key new each time. The
Flux pull secret needs no item. apoci serves pulls anonymously and ignores the credentials, so
`resources.yaml.j2` writes a fixed placeholder.

## kube/clusters/frostlink/bootstrap/resources.yaml.j2

This file creates the secrets that must exist before Flux and ExternalSecrets run. To list them,
run `grep -n -e 'name:' -e 'namespace:' kube/clusters/frostlink/bootstrap/resources.yaml.j2`.
`flux-system/flux-system` is a placeholder, not a Git credential (§ Flux flux-system Secret).

`mise run //kube/clusters/frostlink/bootstrap:base` applies it. That task first creates every
namespace under `kube/clusters/frostlink/apps/`. After that, it applies the CRDs from
`kube/clusters/frostlink/bootstrap/helmfile.d/00-crds.yaml`. During a real bootstrap,
`kube/clusters/frostlink/kubeconfig` does not exist until
`mise run //kube/clusters/frostlink/bootstrap:kubeconfig` runs.

## Cilium / CoreDNS / cert-manager — Install Directly

These three are not in `kube/clusters/frostlink/bootstrap/helmfile.d/01-apps.yaml`.
`mise run //kube/clusters/frostlink/bootstrap:cni` installs all three directly with
`helm upgrade --install`, one per iteration. `phase2` runs it between `base` and `apps`. The task
reads `chart` and `version` from the `ocirepository.yaml` of each app. It looks in the folder of
this cluster first, then in `kube/base/`. It reads `values` from the `helmrelease.yaml` of the app,
merged with `extras/values.yaml` if that file exists. So the install at bootstrap always matches
what is checked in. Nothing is hard-coded, so nothing goes stale.

The reason for not using helmfile (not checked again since the typed-document migration, and it
conflicts with the paragraph below): Talos pre-installs Cilium and CoreDNS with the field manager
`helm-controller`. Helmfile v4 uses the same field manager. So if you apply both, you get SSA
ownership conflicts. The `startupapicheck` Job of cert-manager conflicts too. Direct `helm` CLI
calls use the default field manager (`helm`), so they do not collide. Never add
`--cleanup-on-fail` to a helmfile release. On failure, it deletes cluster-scoped resources. It also
leaves orphaned SSA ownership, which then conflicts on the next try.

Talos never applies its own CNI, CoreDNS or kube-proxy manifests (`oci-talos.md` § Multi-document
format (Talos 1.14), which wins). So there is nothing to clean up before Cilium and CoreDNS take
over.

## OCI DNS — CoreDNS Forward Target

`talosctl get resolvers --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203` shows
`["169.254.169.254"]` on the node.

`/etc/resolv.conf` on the node contains `nameserver 127.0.0.53` (the systemd-resolved stub). Pods
cannot reach this address. So CoreDNS must use `forward . 169.254.169.254`, not the default
`/etc/resolv.conf`.

## Flux flux-system Secret

This secret is not a Git credential. The Flux source is an OCIRepository, not a GitRepository.
`FluxInstance/flux` syncs `oci://registry.frostlink.dev/exikle/frostlink`, which is apoci on
Frostlink. CI pushes there and to the registry of Forgejo. The FluxInstance names this same secret
as its `sync.pullSecret`. There is no `GitRepository` object in the cluster. See
`flux-patterns.md` § Frostlink.

The secret `flux-system/flux-system` is `Opaque`, with the keys `username` and `password`.
`mise run //kube/clusters/frostlink/bootstrap:base` creates it from `resources.yaml.j2` as a fixed
placeholder. apoci ignores it. Flux itself never authenticates to Forgejo. Anything that reaches
Forgejo uses HTTPS, because SSH is not reachable from OCI.

## Cross-namespace dependsOn

A cross-namespace `dependsOn` reference needs an explicit `namespace:` (`flux-patterns.md`
§ Cross-Namespace Kustomization Gotchas).

## After Flux is up — do not sync early

Do not sync the `flux-system` OCIRepository before CI builds the artifact. If you do, Flux resolves
the pre-commit digest again and silently applies old state. This is true during bootstrap and in
normal work (`flux-patterns.md` § Frostlink).

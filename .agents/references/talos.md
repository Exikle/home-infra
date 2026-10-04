# Reference: Talos — Frostlink

## Node Reference

| Node        | Role                           | Management address                                      |
| ----------- | ------------------------------ | ------------------------------------------------------- |
| `frostlink` | Control plane + worker (ARM64) | `10.0.0.203` (OCI internal), reached over the site link |

The node's own tailnet address comes from Headscale and is not pinned —
`kubectl -n network exec deploy/headscale -- headscale nodes list`. `kubeconfig` and `talosconfig`
point at `10.0.0.203`, which Frostlink advertises as a route; see `networking.md` § Access Methods.

Running Talos and Kubernetes versions: `kubectl --kubeconfig kubeconfig get nodes -o wide`
(`OS-IMAGE` and `VERSION` columns).

`allowSchedulingOnControlPlanes: true` — single node runs everything.

## Config Management

Frostlink uses **patch files** in `talos/patches/` — not Jinja2/render-config like Artemis.

### Multi-document format (Talos 1.14)

`talos/patches/controlplane.yaml` moved to the 1.14 typed-document layout on 2026-08-31. It is a
patch over `talosctl gen config`, which on 1.14 already emits 28 typed documents on its own — so
unlike Artemis this repo does not hand-author the mandatory
`KubeAuthorizerConfig`/`KubeAuthenticationConfig` set. The patch adds only what differs from gen.

Being a patch over gen rather than a whole config changes the merge semantics. Three of these are
cluster-breaking if copied from Artemis verbatim:

- **`taints: {$patch: delete}`, never `taints: {}`.** Gen emits
  `KubeNodeConfig.taints: {node-role.kubernetes.io/control-plane: NoSchedule}`, and an empty map
  merges as "add no keys" — the taint **survives** and nothing schedules on the only node.
  Artemis's `taints: {}` is right there only because Artemis authors complete documents. This
  replaces `cluster.allowSchedulingOnControlPlanes: true`.
- **`HostnameConfig` needs `auto: {$patch: delete}`.** Gen emits `auto: stable`, and
  `'auto' and 'hostname' cannot be set at the same time` is a hard validation error.
- **`KubeFlannelCNIConfig` needs an explicit `$patch: delete`.** Gen renders it now, so "no CNI"
  can no longer be expressed by omitting the document.

Other notes:

- `cluster.etcd.extraArgs` is the **only** v1alpha1 block left — there is no etcd document in 1.14.
- Disabled `KubeProxyConfig`/`KubeCoreDNSConfig` still need an explicit `image:`, or the bootstrap
  manifests controller panic-loops. CoreDNS's tag is **Talos's own pin**, not derived from the
  Kubernetes version — read it from the node (`spec.coreDNSImage`), never guess. If Kubernetes
  moves, both tags must be re-derived.
- `machine.nodeLabels` must be dropped — it collides with `KubeNodeConfig.labels`
  (`.machine.nodeLabels is already set in v1alpha1 config`).
- `nodeIP` lives in `KubeNodeConfig` only; setting it on `machine.kubelet` too is an error.
- `KernelModuleConfig name: zfs` carries the load-bearing zfs module. Do not drop it.
- Deliberately **not** adopted: `KubeClusterConfig` (nil-derefs `secrets.RootKubernetesController`
  and brings the control plane back with no apiserver — cost Artemis an outage) and
  `DiscoveryServiceConfig` (would switch public discovery **on**; this cluster reports
  `discoveryEnabled: false`).
- No tuppr `KubeNodeConfig` annotations here, unlike Artemis — the schematic ID must never be
  hand-written; `just talos schematic-id` derives it.

**Migrating a running node is a full config replacement, not a patch.** Documents and their
v1alpha1 equivalents cannot coexist. Never regenerate — that mints new PKI and destroys the
cluster. Take the live `persistent` machine config, delete the migrated v1alpha1 keys, and splice
in complete documents from a patched `gen config`, excluding every gen document carrying
freshly-minted secrets (`KubeAPIServerCAConfig`, `KubeAggregatorCAConfig`,
`KubeServiceAccountConfig`, `KubeEtcdEncryptionConfig`, `DiscoveryIdentityConfig`). Verify with
`talosctl apply-config --dry-run` — and **redirect its output to a file**, because it prints every
private key and token in the config to the terminal.

- `talos/patches/controlplane.yaml` — main machine + cluster config
- `talos/patches/tailscale.yaml.j2` — Tailscale extension service config (1Password auth key reference)

### Changing the Tailscale extension config (Headscale)

`tailscale.yaml.j2` is the source for the live `ExtensionServiceConfig` (logged into Headscale
since 2026-10-02). A rebuild applies it with `just bootstrap tailnet`, which substitutes a freshly
minted one-hour key for the `op://` reference — a fresh node has no tailscale document yet, so a
plain patch is correct there (`bootstrap.md` § Rebuild order). Day-2 changes to the running node
follow the rules below, each of which cost a failed attempt:

- **Replace the document, don't merge it.** Talos merges `environment` lists by appending, so a
  plain patch keeps the old key and flags. Send a `$patch: delete` for the document and the new one
  in the same call: `talosctl patch mc --patch @delete.yaml --patch @<rendered>.yaml`. Render with
  `op inject` into a `chmod 600` temp file; never print it.
- **No reboot** — Talos restarts `ext-tailscale` when the config changes.
- **Use `--mode try --timeout 15m` first**, verify, then confirm. Confirming by re-running the same
  `patch` with `--mode auto` does **not** work: talosctl sees no diff client-side and never calls
  the API, so the rollback stays armed. Confirm by re-sending the active config:
  `talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}' > f` (600, has secrets) then
  `talosctl apply-config --file f --mode no-reboot`.
- **No `--advertise-tags`.** The node's tag (`tag:frostlink`) comes from the Headscale pre-auth key;
  Headscale rejects any requested tag on a pre-auth-key registration.
- **`TS_AUTH_ONCE` stays unset**, so every restart re-applies `TS_EXTRA_ARGS`. Headscale accepts a
  re-used, already-spent key from a node that is already registered.
- **New control server = new `TS_STATE_DIR`.** Pointing it at a fresh directory gives a clean
  identity and leaves the previous one on disk for rollback.

### CRITICAL: never `apply-config` the patch file

`talos/patches/controlplane.yaml` is a **gen-time config patch, not a full machine config**. It has no `machine.token`, no certs, no install config, and no `ExtensionServiceConfig` — the Tailscale auth key exists only in the node's live config, injected from 1Password during bootstrap and never persisted to the repo. `talosctl apply-config` REPLACES the whole config, so pointing it at this file strands the node.

There is no way to regenerate a complete config for this node from the repo alone.

To apply a change, patch the delta instead:

```bash
# 1. write ONLY the changed fields to a patch file, then dry-run it
mise exec -- talosctl --context frostlink patch machineconfig \
  -n 10.0.0.203 --patch-file /tmp/delta.yaml --dry-run

# 2. read the printed diff, then re-run without --dry-run
```

Always `--dry-run` first: it prints the exact config diff and whether a reboot is required. Note the diff includes the Tailscale auth key — do not paste it anywhere.

For changes requiring a reboot: add `--mode reboot`.

**Removing** a field needs the strategic-merge delete directive; a plain `null` is ignored, and JSON6902 patches are rejected outright on this node (`JSON6902 patches are not supported for multi-document machine configuration` — the config is multi-document):

```yaml
machine:
    features:
        someField:
            $patch: delete
```

**Client version matters.** talosctl decodes config documents client-side, so a v1.13 client rejects a v1.14 document with `"KubeTalosAPIAccessConfig" "v1alpha1": not registered` before the node ever sees it. `.mise.toml` pins talosctl to match the cluster; use `mise exec -- talosctl`.

### certSANs minimal patch

```yaml
machine:
    certSANs:
        - <ip-or-hostname>
cluster:
    apiServer:
        certSANs:
            - <ip-or-hostname>
```

## Schematic

Schematic ID: `e7f26ff1516313fd32b377e04c573728c7c942655ecb5580e728ab92bbf4cfc1`

Confirmed three ways on 2026-08-21 — they agree:

| Source                    | How to read it                                                                                      |
| ------------------------- | --------------------------------------------------------------------------------------------------- |
| `talos/schematic.yaml`    | the header comment, and `just talos schematic-id` recomputes it                                     |
| the live node             | `kubectl get node frostlink -o jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'` |
| `talosctl get extensions` | lists the installed extensions themselves                                                           |

Extensions installed — **four, and there is no `qemu-guest-agent`.** OCI A1.Flex does not need
one, and Artemis's `worker`/`gpu` schematics do carry it, so do not copy an extension list
across repos.

| Extension                     | Note                                                                   |
| ----------------------------- | ---------------------------------------------------------------------- |
| `siderolabs/iscsi-tools`      |                                                                        |
| `siderolabs/tailscale`        | all management access rides this; losing it strands the node           |
| `siderolabs/util-linux-tools` |                                                                        |
| `siderolabs/zfs`              | **load-bearing** — the whole `openebs-zfs` storage layer depends on it |

ZFS kernel module is loaded via `machine.kernel.modules: [{name: zfs}]`.

### Never hand-edit a schematic ID, anywhere

tuppr rebuilds the installer from the **node's recorded schematic**, not from
`talos/schematic.yaml`. A stale or hand-written ID therefore silently reinstalls an extension you
removed — or, worse, drops `zfs` and takes every PVC offline. Always derive the ID; never type it.

To add or change an extension:

1. Edit `talos/schematic.yaml`
2. `just talos schematic-id` — recompute the ID (it is `[private]`; `just talos upgrade` calls it)
3. Update the header comment in `talos/schematic.yaml` and the `Schematic:` line in `AGENTS.md`
4. `just talos upgrade <current-talos-version>` — **required.** Editing `schematic.yaml` alone
   changes nothing on the node, and tuppr will keep rebuilding from the old recorded ID until an
   upgrade re-records it. Same Talos version is fine; the point is the reinstall.
5. Re-read the node annotation and confirm it matches

## Talos + Kubernetes Upgrades — owned by tuppr

Upgrades are declarative. Edit the version in
`kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or
`kubernetesupgrade.yaml`), merge, and tuppr performs the upgrade.

Frostlink is a **single node**, so every upgrade is full cluster downtime
(~5 min, roughly 2 min of it API-server down). Draining is skipped
automatically — there is nowhere to drain to — and completion is tracked by
polling node readiness after reboot.

The `TalosUpgrade` sets `policy.rebootMode: powercycle`, matching `just talos upgrade`: the OCI
A1.Flex VM does not come back cleanly from a default (kexec) reboot.

tuppr rebuilds the installer from the node's **runtime-reported schematic**, so
extensions survive an upgrade with no repo change: `.machine.install.image` is
rewritten to `factory.talos.dev/metal-installer/<schematic>:<version>`. If it
cannot resolve a schematic it refuses rather than reinstalling from the generic
installer and wiping extensions.

The flip side: because the **node** is the authority, a schematic change that has
not yet been applied to the node is invisible to tuppr, and an extension deleted
from `talos/schematic.yaml` gets silently reinstalled on the next upgrade. See
§ Schematic — the fix is to run `just talos upgrade` so the node re-records the
new ID.

Note the path is `metal-installer`. Artemis pins the legacy `installer/` prefix to
match its tuppr `factory-url` annotation — **the two clusters differ here on
purpose**, so do not "align" one to the other.

**CSINode topology keys go stale across a tuppr reboot.** tuppr labels the node
`tuppr.home-operations.com/upgrading` for the duration. If the node reboots while
that label is set, zfs-localpv bakes it into CSINode's `topologyKeys`; once tuppr
removes the label the capacity controller builds **0 topology segments**,
publishes no `CSIStorageCapacity`, and then **no new PVC can schedule at all** —
"node(s) did not have enough free storage" against a pool that is 90% free.
After every Talos upgrade, verify a PVC can still bind. Fix:

```bash
kubectl -n openebs-system rollout restart ds/zfs-localpv-node
kubectl -n openebs-system rollout restart deploy/zfs-localpv-controller
```

tuppr triggers on `currentVersion != targetVersion` — **not** a "newer than"
check, and there is no downgrade guard. Never apply a version bump out of band
while Flux still serves the old value from git, or the next reconcile reverts the
CR and tuppr downgrades the node. Either commit the bump, or
`flux suspend ks tuppr-upgrades` first.

### Break-glass: manual upgrade

Only when tuppr is unavailable. Note this uses the legacy
`factory.talos.dev/installer/` path, while tuppr uses `metal-installer`:

```bash
just talos upgrade <version>   # reboots with --reboot-mode powercycle, 10m timeout
just talos schematic-id        # recompute the schematic ID from talos/schematic.yaml
```

`just talos upgrade` resolves the schematic from `talos/schematic.yaml` at run time, so it
installs whatever is currently checked in — which is exactly what tuppr will **not** do. Use it
deliberately, with the current version, and confirm the node annotation afterwards.

No drain/uncordon needed — single node, all workloads restart automatically after reboot.

## Kubernetes Upgrade — break-glass only

tuppr's `KubernetesUpgrade` owns this; `kubectl --kubeconfig kubeconfig get kubernetesupgrades`
shows its current and target version. Bumping the CR is the normal path. Only reach for the
command below when tuppr is unavailable — and expect the next Flux reconcile to fight you if the CR still names the old
version.

```bash
talosctl --context frostlink upgrade-k8s \
  --to <k8s-version> \
  -n 10.0.0.203
```

## Node Health

```bash
talosctl --context frostlink health -n 10.0.0.203
talosctl --context frostlink dmesg -n 10.0.0.203 | tail -30
talosctl --context frostlink version -n 10.0.0.203
talosctl --context frostlink get machineconfig -n 10.0.0.203 -o yaml
```

## Known OCI / Talos Quirks

- **NTP**: `machine.time.servers: [169.254.169.254]` — OCI metadata link-local NTP
- **CoreDNS**: `cluster.coreDNS.disabled: true` — Talos doesn't manage CoreDNS; Flux/Helm deploys it instead
- **CNI**: `cluster.network.cni.name: none` — Cilium manages the CNI (installed via Flux)
- **kube-proxy**: `cluster.proxy.disabled: true` — Cilium handles
- **ZFS disk quotas**: `features.diskQuotaSupport: true` — required for OpenEBS ZFS PVCs
- **hostDNS**: `forwardKubeDNSToHost: true, resolveMemberNames: true` — pod DNS forwarded to host; node names resolve inside pods
- **Cilium on Talos/OCI**: `sysctlfix.enabled: false` required in the Cilium HelmRelease — Talos has no `/etc/sysctl.d/`; cilium-agent init crashes otherwise
- **The `tailscale` extension creates `tailscale0` (MTU 1280)**, which Cilium would auto-detect and use to cap every pod at 1280. The Cilium HelmRelease therefore pins `devices: enp0s6` and `MTU: 1500` — see `networking.md` § cilium `devices` and `MTU` are pinned. Changing or replacing the tailscale patch (e.g. pointing it at Headscale) does not need a Cilium change; adding another host interface that pods must route over does.
- **Talos `clusterName` (`frostlink`) is not Cilium's cluster name.** Talos's comes from `talosctl gen config frostlink` and names the Kubernetes cluster; Cilium's (`frostlink-vps`, ID 2) is set only in the Cilium HelmRelease, for ClusterMesh — see `networking.md` § cilium cluster identity.
- **Forgejo HTTPS only**: SSH unreachable from OCI; Flux uses HTTPS (`username` + `password` fields in secret `flux-system/flux-system`)

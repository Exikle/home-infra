# Reference: Talos — Frostlink

## Node Reference

| Node        | Role                            | IP (Tailscale)   | IP (OCI internal) | Talos  | K8s    |
| ----------- | ------------------------------- | ---------------- | ----------------- | ------ | ------ |
| `frostlink` | Control plane + worker (ARM64)  | `100.67.108.103` | `10.0.0.203`      | v1.14.0-rc.1 | v1.36.1|

`allowSchedulingOnControlPlanes: true` — single node runs everything.

## Config Management

Frostlink uses **patch files** in `talos/patches/` — not Jinja2/render-config like Artemis.

- `talos/patches/controlplane.yaml` — main machine + cluster config
- `talos/patches/tailscale.yaml.j2` — Tailscale extension service config (1Password auth key reference)

### CRITICAL: never `apply-config` the patch file

`talos/patches/controlplane.yaml` is a **gen-time config patch, not a full machine config**. It has no `machine.token`, no certs, no install config, and no `ExtensionServiceConfig` — the Tailscale auth key exists only in the node's live config, injected from 1Password during bootstrap and never persisted to the repo. `talosctl apply-config` REPLACES the whole config, so pointing it at this file strands the node.

There is no way to regenerate a complete config for this node from the repo alone.

To apply a change, patch the delta instead:

```bash
# 1. write ONLY the changed fields to a patch file, then dry-run it
mise exec -- talosctl --context frostlink patch machineconfig \
  -n 40.233.88.33 --patch-file /tmp/delta.yaml --dry-run

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

Current schematic ID: `e7f26ff1516313fd32b377e04c573728c7c942655ecb5580e728ab92bbf4cfc1`

Extensions installed:
- `siderolabs/iscsi-tools`
- `siderolabs/tailscale`
- `siderolabs/util-linux-tools`
- `siderolabs/zfs`

ZFS kernel module is loaded via `machine.kernel.modules: [{name: zfs}]`.

To add or change an extension:

1. Edit `talos/schematic.yaml`
2. Generate new schematic ID:

```bash
just talos schematic-id
```

3. Update the schematic ID in `controlplane.yaml` or patch file
4. Upgrade with the new schematic:

```bash
just talos upgrade <current-talos-version>
```

## Talos + Kubernetes Upgrades — owned by tuppr

Upgrades are declarative. Edit the version in
`kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or
`kubernetesupgrade.yaml`), merge, and tuppr performs the upgrade.

Frostlink is a **single node**, so every upgrade is full cluster downtime
(~5 min, roughly 2 min of it API-server down). Draining is skipped
automatically — there is nowhere to drain to — and completion is tracked by
polling node readiness after reboot.

tuppr rebuilds the installer from the node's **runtime-reported schematic**, so
extensions survive: `.machine.install.image` is rewritten to
`factory.talos.dev/metal-installer/<schematic>:<version>`. If it cannot resolve a
schematic it refuses rather than reinstalling from the generic installer and
wiping extensions.

tuppr triggers on `currentVersion != targetVersion` — **not** a "newer than"
check, and there is no downgrade guard. Never apply a version bump out of band
while Flux still serves the old value from git, or the next reconcile reverts the
CR and tuppr downgrades the node. Either commit the bump, or
`flux suspend ks tuppr-upgrades` first.

### Break-glass: manual upgrade

Only when tuppr is unavailable. Note this uses the legacy
`factory.talos.dev/installer/` path, while tuppr uses `metal-installer`:


```bash
just talos upgrade v1.13.4   # reboots with --reboot-mode powercycle, 10m timeout
just talos schematic-id       # get current schematic ID from factory.talos.dev
```

No drain/uncordon needed — single node, all workloads restart automatically after reboot.

## Kubernetes Upgrade

```bash
talosctl --context frostlink upgrade-k8s \
  --to <k8s-version> \
  -n 100.67.108.103
```

## Node Health

```bash
talosctl --context frostlink health -n 100.67.108.103
talosctl --context frostlink dmesg -n 100.67.108.103 | tail -30
talosctl --context frostlink version -n 100.67.108.103
talosctl --context frostlink get machineconfig -n 100.67.108.103 -o yaml
```

## Known OCI / Talos Quirks

- **NTP**: `machine.time.servers: [169.254.169.254]` — OCI metadata link-local NTP
- **CoreDNS**: `cluster.coreDNS.disabled: true` — Talos doesn't manage CoreDNS; Flux/Helm deploys it instead
- **CNI**: `cluster.network.cni.name: none` — Cilium manages the CNI (installed via Flux)
- **kube-proxy**: `cluster.proxy.disabled: true` — Cilium handles
- **ZFS disk quotas**: `features.diskQuotaSupport: true` — required for OpenEBS ZFS PVCs
- **hostDNS**: `forwardKubeDNSToHost: true, resolveMemberNames: true` — pod DNS forwarded to host; node names resolve inside pods
- **Cilium on Talos/OCI**: `sysctlfix.enabled: false` required in the Cilium HelmRelease — Talos has no `/etc/sysctl.d/`; cilium-agent init crashes otherwise
- **Forgejo HTTPS only**: SSH unreachable from OCI; Flux uses HTTPS (`username` + `password` fields in secret `flux-system/flux-system`)

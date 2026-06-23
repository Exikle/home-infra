# Reference: Talos — Frostlink

## Node Reference

| Node        | Role                            | IP (Tailscale)   | IP (OCI internal) | Talos  | K8s    |
| ----------- | ------------------------------- | ---------------- | ----------------- | ------ | ------ |
| `frostlink` | Control plane + worker (ARM64)  | `100.67.108.103` | `10.0.0.203`      | v1.13.4| v1.36.1|

`allowSchedulingOnControlPlanes: true` — single node runs everything.

## Config Management

Frostlink uses **patch files** in `talos/patches/` — not Jinja2/render-config like Artemis.

- `talos/patches/controlplane.yaml` — main machine + cluster config
- `talos/patches/tailscale.yaml.j2` — Tailscale extension service config (1Password auth key reference)

To apply a change:

```bash
talosctl --context frostlink apply-config \
  --file talos/patches/controlplane.yaml \
  -n 100.67.108.103
```

For changes requiring a reboot: add `--mode reboot`.

### CRITICAL: Never pass a full config as a patch

`talosctl patch machineconfig --patch @file` expects a **delta** (only changed fields). Passing a full `controlplane.yaml` as a patch duplicates array fields (`machine.files`, `machine.certSANs`) — produces read-only filesystem on next boot. Use `apply-config --file` for full config replacement, or a targeted patch file with only the fields to change.

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

## Talos Upgrade

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

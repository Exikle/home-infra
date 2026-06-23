# Skill: Talos Operations

Node operations for Frostlink (single-node ARM64, Oracle Cloud, Talos Linux).

> Also read `.agents/references/talos.md` for node IP and config background.

## Node Reference

| Node        | Role                         | IP (Tailscale)   |
| ----------- | ---------------------------- | ---------------- |
| `frostlink` | Control plane + worker (ARM64) | 100.67.108.103 |

`allowSchedulingOnControlPlanes: true` — the single node runs everything.

---

## Config Changes

Frostlink uses patch files in `talos/patches/` — no Jinja2/render-config templating.

1. Edit the relevant file in `talos/patches/`
2. Get the current config, apply the patch:

```bash
talosctl --context frostlink apply-config \
  --file <patch-file> \
  -n 100.67.108.103
```

For changes requiring a reboot, add `--mode reboot`.

### NEVER use `talosctl patch machineconfig` with a full config

Full config passed as a patch causes array fields (`machine.files`, `machine.certSANs`) to be **duplicated** in the merge, which can produce a read-only filesystem on next boot. Always use `apply-config` with targeted patch files for full config replacement.

### certSANs patch (minimal delta)

```yaml
machine:
    certSANs:
        - <ip-or-hostname>
cluster:
    apiServer:
        certSANs:
            - <ip-or-hostname>
```

Apply: `talosctl --context frostlink apply-config --file patch.yaml -n 100.67.108.103`

---

## Extension / Schematic Changes

Extensions need a new schematic ID and reboot:

1. Edit `talos/schematic.yaml`
2. Get new schematic ID:

```bash
just talos schematic-id
```

3. Update the schematic ID in the relevant patch or config
4. Upgrade with the new schematic:

```bash
just talos upgrade <current-talos-version>
```

---

## Talos Upgrade

```bash
# Get current schematic ID
just talos schematic-id

# Upgrade — reboots automatically (powercycle mode)
just talos upgrade <version>   # e.g. v1.13.4
```

No drain/uncordon needed — single node, all workloads restart automatically after reboot.

---

## Node Health

```bash
talosctl --context frostlink health -n 100.67.108.103
talosctl --context frostlink dmesg -n 100.67.108.103 | tail -30
talosctl --context frostlink version -n 100.67.108.103
talosctl --context frostlink get machineconfig -n 100.67.108.103 -o yaml
```

## Kubernetes Upgrade

```bash
talosctl --context frostlink upgrade-k8s \
  --to <k8s-version> \
  -n 100.67.108.103
```

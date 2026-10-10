---
name: talos-ops
description: Perform Talos node operations — apply a config change, add or change a system extension, upgrade Talos or Kubernetes, reboot or reset a node. Use for "apply talos config", "upgrade talos node", "reboot node", "add a talos extension", or "node config change". Scoped to the Frostlink cluster.
compatibility: Single node — there is nothing to drain to, so any upgrade, reboot or reset is a FULL CLUSTER OUTAGE, not a rolling operation. The destructive guard blocks `talosctl upgrade`/`reboot` for that reason; use `just talos upgrade <version>` and only with the user watching. Requires talosctl and the repo-local talosconfig, reaching 10.0.0.203 over the Headscale site link.
---

# Skill: Talos Operations

Node operations for Frostlink (single-node ARM64, Oracle Cloud, Talos Linux).

> Also read `.agents/references/talos.md` for node IP and config background.

## Node Reference

| Node        | Role                           | Management address                                        |
| ----------- | ------------------------------ | --------------------------------------------------------- |
| `frostlink` | Control plane + worker (ARM64) | `10.0.0.203` (OCI internal), over the Headscale site link |

The public IP `40.233.88.33` is only for a rebuild (`bootstrap.md`) or break-glass when the tailnet
is down (`networking.md` § Access Methods). Every command below uses `10.0.0.203`.

`allowSchedulingOnControlPlanes: true` — the single node runs everything.

---

## Config Changes

Frostlink uses patch files in `talos/patches/` — no Jinja2/render-config templating.

### NEVER `apply-config` the patch file

`talos/patches/controlplane.yaml` is a **gen-time patch, not a full machine config** — no `machine.token`, no certs, no install config, and no `ExtensionServiceConfig` (the Headscale auth key exists only in the node's live config — minted by `just bootstrap tailnet` on a rebuild, or rendered via `op inject` for day-2 changes). `apply-config` replaces the entire config, so pointing it at that file strands the node. Unlike Artemis, this repo cannot regenerate a complete config.

### Applying a change

1. Edit the relevant file in `talos/patches/` so the repo records the intent.
2. Write a **delta** containing only the changed fields, and dry-run it:

```bash
mise exec -- talosctl --context frostlink patch machineconfig \
  -n 10.0.0.203 --patch-file /tmp/delta.yaml --dry-run
```

3. Read the printed diff — it shows exactly what changes and whether a reboot is needed — then re-run without `--dry-run`. The diff contains the Tailscale auth key; never paste it anywhere.

For changes requiring a reboot, add `--mode reboot`.

Use `mise exec -- talosctl`: the client decodes config documents locally, so a mismatched client rejects valid documents (`"KubeTalosAPIAccessConfig" "v1alpha1": not registered`) before the node sees them. `.mise/config.toml` pins the matching version.

### Deleting a field

A plain `null` is ignored and JSON6902 patches are rejected (the config is multi-document). Use the strategic-merge directive:

```yaml
machine:
    features:
        someField:
            $patch: delete
```

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
# Get current schematic ID
just talos schematic-id

# Upgrade — reboots automatically (powercycle mode)
just talos upgrade <version>   # e.g. v1.13.4
```

No drain/uncordon needed — single node, all workloads restart automatically after reboot.

---

## Node Health

```bash
talosctl --context frostlink health -n 10.0.0.203
talosctl --context frostlink dmesg -n 10.0.0.203 | tail -30
talosctl --context frostlink version -n 10.0.0.203
talosctl --context frostlink get machineconfig -n 10.0.0.203 -o yaml
```

## Kubernetes Upgrade

```bash
talosctl --context frostlink upgrade-k8s \
  --to <k8s-version> \
  -n 10.0.0.203
```

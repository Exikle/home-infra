---
name: talos-ops
description: Perform Talos node operations — apply a config change, add or change a system extension, upgrade Talos or Kubernetes, reboot or reset a node. Use for "apply talos config", "upgrade talos node", "reboot node", "add a talos extension", or "node config change". Covers Artemis and Frostlink.
compatibility: Requires `talosctl` (mise pins it to the cluster's running Talos version, and a mismatched client is the usual failure) and a working talosconfig. Node operations are disruptive. Never widen the blast radius beyond the node the user named.
---

# Skill: Talos Operations

Node operations for home-infra (Talos Linux with render-config / Jinja2 templates).

> Also read `.agents/references/talos.md` for node IPs and configuration background.

If you work on Frostlink, read `frostlink.md` in this folder first. Frostlink is one node, so every
upgrade or reboot is a full outage. The steps below are for Artemis.

Goal: apply one Talos change to the named node or nodes. Then make sure that the node came back
healthy.

Success means three things. The node reports the intended configuration. The node is `Ready`. Its
static pods run (`talosctl get staticpods`). This repo has hit a Ready node with missing
control-plane static pods before. That failure shows only on the next reboot.

Stop when the change is applied and verified on the nodes that the user named. Do NOT roll on to
other nodes. Do NOT start a version upgrade that the user did not ask for. Do NOT reboot a second
node until the first is back and healthy.

Edit in a worktree (`mise run //:wt:new <type>/<slug>`, `AGENTS.md` rule 7). Every write verb below
asks for confirmation. So from a non-interactive shell, put `--yes` before the module:
`mise run --yes //kube/clusters/artemis/talos:apply-node <node>` (`.agents/instructions/tooling.md`).

## Config Changes (no reboot)

1. Edit `kube/clusters/artemis/talos/nodes/<node>.yaml.j2`.
2. Run `mise run //kube/clusters/artemis/talos:render-config <node>`.
3. Run `mise run //kube/clusters/artemis/talos:diff-node <node>` for a dry run.
4. Run `mise run --yes //kube/clusters/artemis/talos:apply-node <node>`.

## Config Changes (with reboot)

```bash
mise run //kube/clusters/artemis/talos:render-config <node>
mise run --yes //kube/clusters/artemis/talos:apply-node <node> --mode=reboot
```

If the node runs stateful workloads, drain it first:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# apply + reboot
kubectl uncordon <node>
```

If you mean to empty the node, use `drain`. Do not use a bare `cordon`
(`.agents/references/scheduling.md`).

## Extension Changes

Schematics are per node type, not per node. To list them, run
`ls kube/clusters/artemis/talos/schematics`. `mise run //kube/clusters/artemis/talos:schematic-type <node>`
maps a node name to its type. It is hidden, and it is in `kube/clusters/artemis/talos/mise.toml`.
Extensions need a new schematic ID and a reboot:

1. Edit `kube/clusters/artemis/talos/schematics/<type>.yaml`.
2. Run `mise run //kube/clusters/artemis/talos:schematic-id <type>`. It registers the schematic with
   Sidero Image Factory and prints the ID. It is hidden, so it does not appear in `mise tasks`. It
   is still a real task.
3. Edit nothing by hand. `render-config` computes the ID and injects it into `cluster.yaml.j2` as
   `ENV.SCHEMATIC`.
4. Run `mise run --yes //kube/clusters/artemis/talos:upgrade-node <node>`. The same Talos version
   is fine. `apply-node --mode=reboot` does not reinstall the image, so the new extension does not
   land.
5. Make sure that the `extensions.talos.dev/schematic` annotation of the node shows the new ID
   (`talos.md` § Extension Changes).

## Never change a node by hand

Every Artemis node change goes through its `.yaml.j2` template and `apply-node`. Do not use
`talosctl patch machineconfig` or `talosctl apply-config` directly:

- `apply-config` replaces the whole machine configuration. So a partial file strands the node.
- A full configuration passed to `patch` duplicates array fields such as `machine.files`. The next
  boot can then come up read-only.

The guard blocks `talosctl patch machineconfig` in this repo.

## Node Health

```bash
talosctl health -n <node-ip>
talosctl dmesg -n <node-ip> | tail -30
talosctl version -n <node-ip>
talosctl get machineconfig -n <node-ip> -o yaml
```

## Automated Upgrades (tuppr)

Before you upgrade by hand, look at tuppr. It manages Talos and Kubernetes upgrades through
cluster-scoped CRDs:

```bash
kubectl get talosupgrades,kubernetesupgrades
```

## Manual Talos Upgrade (single node)

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
mise run --yes //kube/clusters/artemis/talos:upgrade-node <node>
kubectl uncordon <node>
```

The task resolves the installer image (schematic plus version) from the rendered configuration. For
Kubernetes, run `mise run --yes //kube/clusters/artemis/talos:upgrade-k8s <version>`.

## Nodes

`ls kube/clusters/artemis/talos/nodes` lists the nodes. `kubectl get nodes -o wide` gives their
roles and IPs.

---
name: talos-ops
description: Perform Talos node operations — apply a config change, add or change a system extension, upgrade Talos or Kubernetes, reboot or reset a node. Use for "apply talos config", "upgrade talos node", "reboot node", "add a talos extension", or "node config change". Covers Artemis and Frostlink.
compatibility: Requires `talosctl` (mise pins it to the cluster's running Talos version, and a mismatched client is the usual failure) and a working talosconfig. Node operations are disruptive. Never widen the blast radius beyond the node the user named.
---

# Skill: Talos Operations

Node operations for home-infra (Talos Linux with render-config / Jinja2 templates).

> Also read `.agents/references/talos.md` for node IPs and config background.

On Frostlink (one node, so every upgrade or reboot is a full outage), read `frostlink.md` in this
folder first. The steps below are Artemis.

Goal: apply one Talos change to the named node(s) and confirm that the node came back healthy.

Success means that the node reports the intended config, is `Ready`, and its static pods
run (`talosctl get staticpods`). A Ready node with missing control-plane static pods is the
failure this repo has hit before, and it only shows on the next reboot.

Stop when the change is applied and verified on the node(s) that the user named. Do NOT roll on
to other nodes. Do NOT start a version upgrade that the user did not ask for. Do NOT reboot a
second node until the first is back and healthy.

Edit in a worktree (`mise run //:wt:new <type>/<slug>`, `AGENTS.md` rule 7). Every write verb below is
confirm-gated, so from a non-interactive shell put `--yes` before the module:
`mise run --yes //clusters/artemis/talos:apply-node <node>` (`.agents/instructions/tooling.md`).

## Config Changes (no reboot)

1. Edit `clusters/artemis/talos/nodes/<node>.yaml.j2`.
2. Run `mise run //clusters/artemis/talos:render-config <node>`, then `mise run //clusters/artemis/talos:diff-node <node>` for a dry run.
3. Run `mise run --yes //clusters/artemis/talos:apply-node <node>`.

## Config Changes (with reboot)

```bash
mise run //clusters/artemis/talos:render-config <node>
mise run --yes //clusters/artemis/talos:apply-node <node> --mode=reboot
```

If the node runs stateful workloads, drain it first:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# apply + reboot
kubectl uncordon <node>
```

Use `drain` when you mean to empty the node. Do not use a bare `cordon` (`.agents/references/scheduling.md`).

## Extension Changes

Schematics are per node type, not per node: run `ls clusters/artemis/talos/schematics`. `mise run //clusters/artemis/talos:schematic-type <node>`
(hidden, in `clusters/artemis/talos/mise.toml`) maps a node name to its type. Extensions need a new schematic ID
and a reboot:

1. Edit `clusters/artemis/talos/schematics/<type>.yaml`.
2. Run `mise run //clusters/artemis/talos:schematic-id <type>`. It registers the schematic with Sidero Image Factory and prints the ID. It is
   hidden, so it does not appear in `mise tasks`, but it is still a real task.
3. Edit nothing by hand. `render-config` computes the ID and injects it into `cluster.yaml.j2` as
   `ENV.SCHEMATIC`.
4. Run `mise run --yes //clusters/artemis/talos:apply-node <node> --mode=reboot`.

## NEVER use `talosctl patch machineconfig` with a full config

If you pass a full config as a patch, array fields (`machine.files`, `machine.certSANs`) are **duplicated** in the merge. This can produce a read-only filesystem on the next boot. Always use one of these:

- `mise run //clusters/artemis/talos:apply-node <node>` for full config replacement (render-config output)
- A minimal 6-line delta patch file for targeted changes (for example, certSANs only)

Minimal certSANs patch example:

```yaml
machine:
    certSANs:
        - <ip-or-hostname>
cluster:
    apiServer:
        certSANs:
            - <ip-or-hostname>
```

Apply: `talosctl apply-config --file patch.yaml -n <node-ip>`

## Node Health

```bash
talosctl health -n <node-ip>
talosctl dmesg -n <node-ip> | tail -30
talosctl version -n <node-ip>
talosctl get machineconfig -n <node-ip> -o yaml
```

## Automated Upgrades (tuppr)

Check tuppr before you upgrade by hand. It manages Talos and Kubernetes upgrades through cluster-scoped
CRDs:

```bash
kubectl get talosupgrades,kubernetesupgrades
```

## Manual Talos Upgrade (single node)

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
mise run --yes //clusters/artemis/talos:upgrade-node <node>
kubectl uncordon <node>
```

The task resolves the installer image (schematic plus version) from the rendered config. For Kubernetes, run
`mise run --yes //clusters/artemis/talos:upgrade-k8s <version>`.

## Nodes

`ls clusters/artemis/talos/nodes` lists them and `kubectl get nodes -o wide` gives roles and IPs.

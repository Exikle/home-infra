---
name: talos-ops
description: Perform Talos node operations — apply a config change, add or change a system extension, upgrade Talos or Kubernetes, reboot or reset a node. Use for "apply talos config", "upgrade talos node", "reboot node", "add a talos extension", or "node config change". Scoped to the Frostlink cluster.
compatibility: Single node — there is nothing to drain to, so any upgrade, reboot or reset is a FULL CLUSTER OUTAGE, not a rolling operation. The destructive guard blocks `talosctl upgrade`/`reboot` for that reason; use `just talos upgrade <version>` and only with the user watching. Requires talosctl and the repo-local talosconfig, reaching 10.0.0.203 over the Headscale site link.
---

# Skill: Talos Operations

Node operations for Frostlink (single node, `10.0.0.203` over the Headscale site link). The
background and the rationale for every step below are in `.agents/references/talos.md`; read the
named section before acting.

`talosctl` has no merged-config fallback, so always pass the repo talosconfig (tooling.md § kubectl
and talosctl scoping):

```bash
talosctl version --talosconfig /home/exikle/frostlink/talosconfig -n 10.0.0.203
```

Use `kubectl ... --context frostlink` and `flux ... --context frostlink` for the cluster side.

## Config change

`talos/patches/controlplane.yaml` is a gen-time patch, **not** a full machine config. Never
`apply-config` it: that strands the node (`talos.md` § CRITICAL: never `apply-config` the patch
file).

1. Edit the file in `talos/patches/` so the repo records the intent.
2. Write a **delta** with only the changed fields to a scratch file and dry-run it:

    ```bash
    mise exec -- talosctl patch machineconfig --talosconfig /home/exikle/frostlink/talosconfig -n 10.0.0.203 --patch-file <delta.yaml> --dry-run
    ```

3. Read the printed diff (it shows whether a reboot is needed; it contains the Tailscale auth key,
   so never paste it), then re-run without `--dry-run`. Add `--mode reboot` if a reboot is needed.

Config-document commands (`patch`, `apply-config`) use `mise exec -- talosctl` so the client
version matches the cluster. Removing a field, the client-version trap and the certSANs delta:
`talos.md` § CRITICAL and § certSANs minimal patch.

## Extension / schematic change

A new extension needs a new schematic and an upgrade (`talos.md` § Schematic). Never hand-edit a
schematic ID.

1. Edit `talos/schematic.yaml`.
2. Derive the ID: `just talos schematic-id`.
3. Update the header comment in `talos/schematic.yaml` with the new ID.
4. Run `just talos upgrade <current-version>` so the node records the new schematic. The current
   version is `talosctl version`, not a number from a doc.
5. Re-read the node annotation (`kubectl get node frostlink --context frostlink -o
   jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'`) and confirm it matches.

## Upgrades

Upgrades are owned by tuppr: edit the version in
`kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or `kubernetesupgrade.yaml`)
and merge. It is full cluster downtime (`talos.md` § Talos + Kubernetes Upgrades — owned by
tuppr).

- Never apply a bump out of band while Flux still serves the old value from git, or tuppr
  downgrades the node. Commit it, or first:

    ```bash
    flux suspend ks tuppr-upgrades -n system-upgrade --context frostlink
    ```

- After every Talos upgrade verify a new PVC can still bind (CSINode topology keys,
  `storage.md` § Gotcha: stale CSINode topology keys block every new PVC).
- Break-glass manual upgrade (`just talos upgrade <version>`) and `upgrade-k8s`: `talos.md`
  § Break-glass: manual upgrade, § Kubernetes Upgrade — break-glass only.

## Node health

```bash
talosctl health --talosconfig /home/exikle/frostlink/talosconfig -n 10.0.0.203
talosctl dmesg --talosconfig /home/exikle/frostlink/talosconfig -n 10.0.0.203
talosctl get machineconfig --talosconfig /home/exikle/frostlink/talosconfig -n 10.0.0.203 -o yaml   # contains the auth key; never paste
```

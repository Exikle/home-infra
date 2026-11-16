# Talos Operations on Frostlink

Frostlink is a single node (`10.0.0.203`, over the Headscale site link). There is nothing to
drain to, so any upgrade, reboot or reset is a full cluster outage. The destructive guard blocks
`talosctl upgrade` and `talosctl reboot` for that reason. Do them only with the user watching.

The background is in `.agents/references/oci-talos.md`. Read the named section before you act.
The task names differ from Artemis. Frostlink has only `mise run //kube/clusters/frostlink/talos:upgrade <version>`
and `mise run //kube/clusters/frostlink/talos:schematic-id`. There is no `apply-node` and no `render-config`.

`talosctl` has no merged-config fallback, so always pass the repo talosconfig:

```bash
talosctl version --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203
```

Use `kubectl ... --context frostlink` and `flux ... --context frostlink` for the cluster side.

## Config change

`kube/clusters/frostlink/talos/patches/controlplane.yaml` is a gen-time patch, **not** a full machine
config. Never `apply-config` it, because that strands the node (`oci-talos.md` § CRITICAL: never
`apply-config` the patch file).

1. Edit the file in `kube/clusters/frostlink/talos/patches/` so the repo records the intent.
2. Write a **delta** with only the changed fields to a scratch file and dry-run it:

    ```bash
    mise exec -- talosctl patch machineconfig --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 --patch-file <delta.yaml> --dry-run
    ```

3. Read the printed diff. It shows whether a reboot is needed. It contains the Tailscale auth
   key, so never paste it. Then re-run without `--dry-run`. Add `--mode reboot` if a reboot is needed.

Config-document commands (`patch`, `apply-config`) use `mise exec -- talosctl`, so the client
version matches the cluster. Removing a field, the client-version trap and the certSANs delta are
in `oci-talos.md` § CRITICAL and § certSANs minimal patch.

## Extension or schematic change

A new extension needs a new schematic and an upgrade (`oci-talos.md` § Schematic). Never hand-edit
a schematic ID.

1. Edit `kube/clusters/frostlink/talos/schematic.yaml`.
2. Derive the ID: `mise run //kube/clusters/frostlink/talos:schematic-id`.
3. Update the header comment in `kube/clusters/frostlink/talos/schematic.yaml` with the new ID.
4. Run `mise run //kube/clusters/frostlink/talos:upgrade <current-version>` so the node records the new
   schematic. The current version is `talosctl version`, not a number from a doc.
5. Re-read the node annotation and confirm it matches:

    ```bash
    kubectl get node frostlink --context frostlink -o jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'
    ```

## Upgrades

tuppr owns upgrades. Edit the version in
`kube/clusters/frostlink/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or
`kubernetesupgrade.yaml`) and merge. It is full cluster downtime (`oci-talos.md` § Talos + Kubernetes
Upgrades — owned by tuppr).

- Never apply a bump out of band while Flux still serves the old value from git, or tuppr
  downgrades the node. Commit it, or first suspend tuppr:

    ```bash
    flux suspend ks tuppr-upgrades -n system-upgrade --context frostlink
    ```

- After every Talos upgrade, verify that a new PVC can still bind (CSINode topology keys,
  `openebs-zfs.md` § Gotcha: stale CSINode topology keys block every new PVC).
- The break-glass manual upgrade is `mise run //kube/clusters/frostlink/talos:upgrade <version>`. It and
  `upgrade-k8s` are in `oci-talos.md` § Break-glass: manual upgrade and § Kubernetes Upgrade — break-glass only.

## Node health

```bash
talosctl health --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203
talosctl dmesg --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203
talosctl get machineconfig --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 -o yaml   # contains the auth key; never paste
```

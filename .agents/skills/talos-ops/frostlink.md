# Talos Operations on Frostlink

Frostlink is a single node (`10.0.0.203`, over the Headscale site link). There is no other node to
drain to. So any upgrade, reboot or reset is a full cluster outage. For that reason, the destructive
guard blocks `talosctl upgrade` and `talosctl reboot`. Do these operations only with the user
watching.

The background is in `.agents/references/oci-talos.md`. Read the named section before you act.

The task names differ from Artemis. Frostlink has four Talos tasks. `upgrade <version>` upgrades
the node. `schematic-id` derives the schematic ID. `diff-patch <file>` and `patch-node <file>`
dry-run and apply a delta patch. All four are under `//kube/clusters/frostlink/talos`. There is no
`apply-node` and no `render-config`.

`talosctl` has no merged-configuration fallback. So always pass the repo talosconfig:

```bash
talosctl version --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203
```

For the cluster side, use `kubectl ... --context frostlink` and `flux ... --context frostlink`.

## Config change

`kube/clusters/frostlink/talos/patches/controlplane.yaml` is a gen-time patch. It is not a full
machine configuration. Never `apply-config` it, because that strands the node (`oci-talos.md`
§ CRITICAL: never `apply-config` the patch file).

1. Edit the file in `kube/clusters/frostlink/talos/patches/`, so that the repo records the intent.
2. Write a delta with only the changed fields to a scratch file.
3. Dry-run the delta: `mise run //kube/clusters/frostlink/talos:diff-patch <delta.yaml>`.
4. Read the printed diff. It shows whether a reboot is needed. It can contain the Tailscale auth
   key, so never paste it.
5. Hand the apply to the user, or run it with the user watching:
   `mise run --yes //kube/clusters/frostlink/talos:patch-node <delta.yaml>`. The default mode is
   `auto`. A reboot is a full outage.

Both tasks refuse any file under `kube/clusters/frostlink/talos/patches/`. Do not run
`talosctl patch` or `talosctl apply-config` directly. The guard blocks the patch verb. How to remove
a field, and the certSANs delta, are in `oci-talos.md` § CRITICAL and § certSANs minimal patch.

## Extension or schematic change

A new extension needs a new schematic and an upgrade (`oci-talos.md` § Schematic). Never hand-edit
a schematic ID.

1. Edit `kube/clusters/frostlink/talos/schematic.yaml`.
2. Derive the ID: `mise run //kube/clusters/frostlink/talos:schematic-id`.
3. Update the header comment in `kube/clusters/frostlink/talos/schematic.yaml` with the new ID.
4. Run `mise run //kube/clusters/frostlink/talos:upgrade <current-version>`, so that the node records
   the new schematic. Get the current version from `talosctl version`, not from a number in a doc.
5. Read the node annotation again and make sure that it matches:

    ```bash
    kubectl get node frostlink --context frostlink -o jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'
    ```

## Upgrades

tuppr owns upgrades. Edit the version in
`kube/clusters/frostlink/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or
`kubernetesupgrade.yaml`) and merge. The upgrade is full cluster downtime (`oci-talos.md` § Talos +
Kubernetes Upgrades — owned by tuppr).

- Never apply a bump out of band while Flux still serves the old value from git. If you do, tuppr
  downgrades the node. Commit the bump, or suspend tuppr first:

    ```bash
    flux suspend ks tuppr-upgrades -n system-upgrade --context frostlink
    ```

- After every Talos upgrade, make sure that a new PVC can still bind (CSINode topology keys,
  `openebs-zfs.md` § Gotcha: stale CSINode topology keys block every new PVC).
- The break-glass manual upgrade is `mise run //kube/clusters/frostlink/talos:upgrade <version>`.
  It and `upgrade-k8s` are in `oci-talos.md` § Break-glass: manual upgrade and § Kubernetes
  Upgrade — break-glass only.

## Node health

```bash
talosctl health --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203
talosctl dmesg --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203
talosctl get machineconfig --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 -o yaml   # contains the auth key; never paste
```

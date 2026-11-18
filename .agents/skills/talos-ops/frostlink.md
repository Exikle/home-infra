# Talos Operations on Frostlink

Frostlink is a single node (`10.0.0.203`, over the Headscale site link). There is no other node to
drain to. So any upgrade, reboot or reset is a full cluster outage. For that reason, the destructive
guard blocks `talosctl upgrade` and `talosctl reboot`. Do these operations only with the user
watching.

The background is in `.agents/references/oci-talos.md`, which wins over this file. Read the named
section before you act.

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
   `auto`. `--mode` also takes `no-reboot`, `staged` or `try`. A reboot is a full outage.

Both tasks refuse any file under `kube/clusters/frostlink/talos/patches/`. Do not run
`talosctl patch` or `talosctl apply-config` directly. The guard blocks the patch verb. How to remove
a field is in `oci-talos.md` § CRITICAL.

## Extension or schematic change

A new extension needs a new schematic and an upgrade (`oci-talos.md` § Schematic). Never hand-edit
a schematic ID, and never read it from a comment in a file.

1. Edit `kube/clusters/frostlink/talos/schematic.yaml`.
2. Derive the ID: `mise run //kube/clusters/frostlink/talos:schematic-id`.
3. Run `mise run --yes //kube/clusters/frostlink/talos:upgrade <current-version>`, with the user
   watching, so that the node records the new schematic. Get the current version from
   `talosctl version`, not from a number in a doc.
4. Read the node annotation again and make sure that it matches the ID from step 2:

    ```bash
    kubectl get node frostlink --context frostlink -o jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'
    ```

## Upgrades

tuppr owns upgrades. Edit the version in
`kube/clusters/frostlink/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or
`kubernetesupgrade.yaml`) and merge. The upgrade is full cluster downtime (`oci-talos.md` § Talos +
Kubernetes Upgrades — owned by tuppr).

- Never apply a bump out of band while Flux still serves the old value from git. If you do, tuppr
  downgrades the node. Commit the bump. To test it live first, run
  `mise run //kube/clusters/frostlink:test-ks system-upgrade tuppr-upgrades` from the worktree. It
  suspends the root and `tuppr-upgrades`. After the user confirms, `land` commits the bump, waits
  for the artifact and resumes both (`commit-style.md` § The sequence).
- After every Talos upgrade, make sure that a new PVC can still bind (CSINode topology keys,
  `openebs-zfs.md` § Gotcha: stale CSINode topology keys block every new PVC).
- The break-glass Talos upgrade is `mise run --yes //kube/clusters/frostlink/talos:upgrade <version>`
  (`oci-talos.md` § Break-glass: manual upgrade). Use it only when tuppr is not available.
- The break-glass Kubernetes upgrade is a raw `talosctl upgrade-k8s` (`oci-talos.md` § Kubernetes
  Upgrade — break-glass only). The guard blocks it, so hand the command to the user.

## Node health

The commands are in `oci-talos.md` § Node Health. The output of `get machineconfig` contains the
Tailscale auth key. Never paste it.

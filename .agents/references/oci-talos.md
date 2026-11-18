# Reference: Frostlink Talos

## Node Reference

There is one node, `frostlink`. It is both control plane and worker (ARM64). You manage it at
`10.0.0.203` over the site link (`oci-networking.md` § Access Methods). The tailnet address of
the node comes from Headscale and is not pinned. To read it, run
`kubectl exec deploy/headscale -n network -c app --context frostlink -- headscale nodes list`.

To read the running Talos and Kubernetes versions, run `kubectl get nodes -o wide --context frostlink`
(the `OS-IMAGE` and `VERSION` columns).

The single node runs everything, because the patch deletes the control-plane taint (§ Config
Management below).

Every `talosctl` command on this page needs the client version that `.mise/config.toml` pins. The
`talosctl` on the PATH of an agent shell can be older. Run each one as `mise exec -- talosctl`
(§ CRITICAL: never `apply-config` the patch file says why the version matters).

## Config Management

Frostlink uses patch files in `kube/clusters/frostlink/talos/patches/`. It does not use
Jinja2/render-config like Artemis.

### Multi-document format (Talos 1.14)

`kube/clusters/frostlink/talos/patches/controlplane.yaml` uses the 1.14 typed-document layout. It is
a patch over `talosctl gen config`. On 1.14, gen already emits the full typed-document set. So,
unlike Artemis, Frostlink does not write the mandatory
`KubeAuthorizerConfig`/`KubeAuthenticationConfig` set by hand. The patch adds only what differs from
gen.

Because it is a patch over gen and not a whole configuration, the merge rules change. If you copy
these three from Artemis as they are, they break the cluster:

- Use `taints: {$patch: delete}`, never `taints: {}`. Gen emits
  `KubeNodeConfig.taints: {node-role.kubernetes.io/control-plane: NoSchedule}`. An empty map merges
  as "add no keys". So the taint survives, and nothing schedules on the only node. `taints: {}` is
  correct on Artemis only because Artemis writes complete documents. This replaces
  `cluster.allowSchedulingOnControlPlanes: true`.
- `HostnameConfig` needs `auto: {$patch: delete}`. Gen emits `auto: stable`, and
  `'auto' and 'hostname' cannot be set at the same time` is a hard validation error.
- `KubeFlannelCNIConfig` needs an explicit `$patch: delete`. Gen now renders it. So you can no
  longer express "no CNI" by leaving the document out.

Other notes:

- `cluster.etcd.extraArgs` is the only v1alpha1 block left. There is no etcd document in 1.14.
- A disabled `KubeProxyConfig` or `KubeCoreDNSConfig` still needs an explicit `image:`. Without it,
  the bootstrap manifests controller panic-loops. Talos pins the CoreDNS tag itself. The tag does
  not come from the Kubernetes version. Read it from the node (`spec.coreDNSImage`). Never guess
  it. If Kubernetes moves, you must derive both tags again.
- Drop `machine.nodeLabels`. It collides with `KubeNodeConfig.labels`
  (`.machine.nodeLabels is already set in v1alpha1 config`).
- `nodeIP` lives in `KubeNodeConfig` only. If you also set it on `machine.kubelet`, you get an
  error.
- `KernelModuleConfig name: zfs` carries the zfs module, which is load-bearing. Do not drop it.
- Two documents are not used, on purpose:
    - `KubeClusterConfig`. It nil-derefs `secrets.RootKubernetesController` and brings the control
      plane back with no apiserver. It cost Artemis an outage.
    - `DiscoveryServiceConfig`. It turns public discovery on. Frostlink reports
      `discoveryEnabled: false`.
- There are no tuppr `KubeNodeConfig` annotations here, unlike Artemis. Never write the schematic ID
  by hand. `mise run //kube/clusters/frostlink/talos:schematic-id` derives it.

To migrate a running node, you must replace the full configuration. A patch is not enough. Documents
and their v1alpha1 equivalents cannot exist together. Never regenerate the configuration. That
makes new PKI and destroys the cluster. Do this instead:

1. Take the live `persistent` machine configuration.
2. Delete the v1alpha1 keys that you migrate.
3. Splice in complete documents from a patched `gen config`. Leave out every gen document that
   carries newly made secrets: `KubeAPIServerCAConfig`, `KubeAggregatorCAConfig`,
   `KubeServiceAccountConfig`, `KubeEtcdEncryptionConfig` and `DiscoveryIdentityConfig`.
4. Test the result with
   `talosctl apply-config --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 --dry-run`. Redirect its
   output to a file. It prints every private key and token in the configuration to the terminal.

The patch files:

- `kube/clusters/frostlink/talos/patches/controlplane.yaml`: the main machine and cluster
  configuration
- `kube/clusters/frostlink/talos/patches/tailscale.yaml.j2`: the configuration of the Tailscale
  extension service (it references the 1Password auth key)
- `kube/clusters/frostlink/talos/patches/firewall.yaml`: the host ingress firewall, day-2 only
  (§ Host ingress firewall)

### Host ingress firewall

`firewall.yaml` is one `NetworkRuleConfig` in default-accept mode. Every TCP port except 80, 443 and
50000 accepts only the pod CIDR, the tailnet and the home subnets.

The rule exists because hostNetwork listeners bind every address. These include the towonel TCP
services (15001 and up, no bind option in 1.13.7), the API server, etcd, the kubelet, and the
plain-HTTP hub API on 8443. Without the rule, the OCI security list was the only layer between them
and the internet.

The rule does not touch 80, 443, 50000, UDP or ICMP. So it cannot cut management access. Pods can
still reach hostNetwork ports (the backhaul endpoint, metrics) through the pod CIDR. You apply it
live, with no reboot.

- It is not in `gen config`. During a rebuild, you reach 6443 from the home public /32 before the
  tailnet exists. This rule blocks that. Apply it after
  `mise run //kube/clusters/frostlink/bootstrap:tailnet`.
- To apply or change it:
    1. Run
       `talosctl patch mc --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 --patch @kube/clusters/frostlink/talos/patches/firewall.yaml --mode try --timeout 10m`.
    2. Make sure that new connections work.
       `talosctl get nftableschain --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203`
       shows `ingress` and `prerouting`. Test talosctl through `-e 40.233.88.33`, kubectl, and the front door. The query
       `up == 0` in VictoriaMetrics must be empty.
    3. Confirm by sending the active configuration again, as shown in the next section.
- To remove it, send a `$patch: delete` document for the `NetworkRuleConfig` `tcp-internal-only`.
- If you add a new public TCP port, carve its range out of the rule. Otherwise it stays
  internal-only.

### Changing the Tailscale extension config (Headscale)

`tailscale.yaml.j2` is the source for the live `ExtensionServiceConfig`, which is logged into
Headscale. A rebuild applies it with `mise run //kube/clusters/frostlink/bootstrap:tailnet`. That
task puts a newly made one-hour key in place of the `op://` reference. A fresh node has no tailscale
document yet, so a plain patch is correct there (`oci-rebuild.md` § Rebuild order).

Day-2 changes to the running node follow the rules below. Each rule cost a failed attempt:

- Replace the document. Do not merge it. Talos merges `environment` lists by appending, so a plain
  patch keeps the old key and flags. Send a `$patch: delete` for the document and the new document
  in the same call:
  `talosctl patch mc --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 --patch @delete.yaml --patch @<rendered>.yaml`.
  Render with `op inject` into a temporary file with `chmod 600`. Never print it.
- Do not reboot. Talos restarts `ext-tailscale` when the configuration changes.
- Use `--mode try --timeout 15m` first. Make sure that it works, then confirm. To confirm, you cannot
  run the same `patch` again with `--mode auto`. talosctl sees no diff on the client side and never
  calls the API, so the rollback stays armed. Confirm by sending the active configuration again:
    1. Run
       `talosctl get machineconfig v1alpha1 --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 -o jsonpath='{.spec}' > f`.
       Set the file to 600, because it has secrets.
    2. Run
       `talosctl apply-config --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203 --file f --mode no-reboot`.
- Do not use `--advertise-tags`. The tag of the node (`tag:frostlink`) comes from the Headscale
  pre-auth key. Headscale rejects any requested tag on a pre-auth-key registration.
- Leave `TS_AUTH_ONCE` unset. Then every restart applies `TS_EXTRA_ARGS` again. Headscale accepts a
  re-used key that is already spent, from a node that is already registered.
- For a new control server, use a new `TS_STATE_DIR`. A fresh directory gives a clean identity. The
  previous identity stays on disk for rollback.

### CRITICAL: never `apply-config` the patch file

`kube/clusters/frostlink/talos/patches/controlplane.yaml` is a config patch for gen time. It is not a
full machine configuration. It has no `machine.token`, no certs, no install configuration, and no
`ExtensionServiceConfig`.

The Headscale auth key exists only in the live configuration of the node. On a rebuild,
`mise run //kube/clusters/frostlink/bootstrap:tailnet` makes it. For day-2 changes, `op inject`
renders it. It is never stored in git.

`talosctl apply-config` REPLACES the whole configuration. So if you point it at this file, it strands
the node. You cannot make a complete configuration for this node from git alone.

To apply a change, patch only the delta:

```bash
# 1. write ONLY the changed fields to a delta file, then dry-run it
mise run //kube/clusters/frostlink/talos:diff-patch <delta.yaml>

# 2. read the printed diff, then apply with the user watching
mise run --yes //kube/clusters/frostlink/talos:patch-node <delta.yaml> [--mode auto|no-reboot|staged|try]
```

The dry-run prints the configuration diff and says whether a reboot is required. The diff can
include the Tailscale auth key. Do not paste it anywhere. Both tasks refuse files under
`kube/clusters/frostlink/talos/patches/`. `talosctl patch` has no reboot mode. `auto` reboots when
the change needs it.

`talosctl patch machineconfig --patch` expects a DELTA, with only the changed fields. If you pass a
full configuration, it duplicates array fields (for example `machine.files`) and breaks the node on
the next boot. Use a minimal patch file. For a full replacement, use `talosctl apply-config --file`.

To remove a field, use the strategic-merge delete directive. A plain `null` is ignored. This node
rejects JSON6902 patches completely, because the configuration is multi-document
(`JSON6902 patches are not supported for multi-document machine configuration`):

```yaml
machine:
    features:
        someField:
            $patch: delete
```

The client version matters. talosctl decodes configuration documents on the client side. So a v1.13
client rejects a v1.14 document with `"KubeTalosAPIAccessConfig" "v1alpha1": not registered` before
the node sees it. `.mise/config.toml` pins talosctl to match the cluster. Use `mise exec -- talosctl`.

## Schematic

Never type the schematic ID into docs or files. The ID of the checked-in schematic comes only
from `mise run //kube/clusters/frostlink/talos:schematic-id`. The task sends
`kube/clusters/frostlink/talos/schematic.yaml` to factory.talos.dev and prints the ID. Do not read
the ID from a comment in a file.

To read what the node runs, use one of these commands:

- The live node:
  `kubectl get node frostlink --context frostlink -o jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'`.
- The list of installed extensions:
  `talosctl get extensions --talosconfig kube/clusters/frostlink/talosconfig -n 10.0.0.203`.

The ID from the task and the ID on the live node must agree. The installed extensions must match
the list in `schematic.yaml`.

The extensions are in `kube/clusters/frostlink/talos/schematic.yaml`. There are four, and there is no
`qemu-guest-agent`. OCI A1.Flex does not need one. The `worker` and `gpu` schematics of Artemis do
carry it. So do not copy an extension list between the clusters. `siderolabs/zfs` is load-bearing:
it is the whole `openebs-zfs` storage layer. `siderolabs/tailscale` carries all management access.
If you lose either one, the node is stranded. `KernelModuleConfig name: zfs` loads the ZFS kernel
module.

### Never hand-edit a schematic ID, anywhere

tuppr rebuilds the installer from the schematic that the node recorded. It does not use
`kube/clusters/frostlink/talos/schematic.yaml`. So a stale or hand-written ID silently reinstalls an
extension that you removed. Worse, it can drop `zfs` and take every PVC offline. Always derive the
ID. Never type it.

To add or change an extension:

1. Edit `kube/clusters/frostlink/talos/schematic.yaml`.
2. Run `mise run //kube/clusters/frostlink/talos:schematic-id` to compute the ID again. The task is
   hidden (`hide = true`), so a plain `mise tasks` does not list it.
   `mise run //kube/clusters/frostlink/talos:upgrade` calls it.
3. Run `mise run //kube/clusters/frostlink/talos:upgrade <current-talos-version>`. This step is
   required. An edit to `schematic.yaml` alone changes nothing on the node. tuppr keeps rebuilding
   from the old recorded ID until an upgrade records the new one. The same Talos version is fine.
   The point is the reinstall.
4. Read the node annotation again and make sure that it matches.

## Talos + Kubernetes Upgrades — owned by tuppr

Upgrades are declarative. Edit the version in
`kube/clusters/frostlink/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or
`kubernetesupgrade.yaml`), then commit and push. tuppr then does the upgrade.

Frostlink is a single node, so every upgrade is full cluster downtime. tuppr skips draining
automatically, because there is no other node to drain to. It tracks completion by polling node
readiness after the reboot.

The `TalosUpgrade` sets `policy.rebootMode: powercycle`. This matches
`mise run //kube/clusters/frostlink/talos:upgrade`. The OCI A1.Flex VM does not come back cleanly
from a default (kexec) reboot.

The memory limit of the tuppr controller is large on purpose. In steady state it uses about 77Mi.
But with a 128Mi limit, it was OOMKilled (exit 137) during informer sync, before it became ready. An
OOM in the middle of a Talos upgrade is the worst case.

tuppr rebuilds the installer from the schematic that the node reports at runtime. So extensions
survive an upgrade with no repo change. tuppr rewrites `.machine.install.image` to
`factory.talos.dev/metal-installer/<schematic>:<version>`. If it cannot resolve a schematic, it
refuses. It does not reinstall from the generic installer. That installer wipes the extensions.

The other side of this: the node is the authority. So tuppr cannot see a schematic change that you
did not yet apply to the node. An extension that you deleted from
`kube/clusters/frostlink/talos/schematic.yaml` is silently reinstalled on the next upgrade. See
§ Schematic. The fix is to run `mise run //kube/clusters/frostlink/talos:upgrade` so that the node
records the new ID.

Note that the path is `metal-installer`. Artemis pins the legacy `installer/` prefix to match its
tuppr `factory-url` annotation. The two clusters differ here on purpose. Do not "align" one to the
other.

CSINode topology keys can go stale across a tuppr reboot. After that, no new PVC can schedule. After
every Talos upgrade, make sure that a PVC can still bind. The fix is in `openebs-zfs.md` § Gotcha:
stale CSINode topology keys block every new PVC.

tuppr starts an upgrade when `currentVersion != targetVersion`. It does not test "newer than", and
there is no guard against a downgrade. Never apply a version bump out of band while Flux still
serves the old value from git. If you do, the next reconcile reverts the CR, and tuppr downgrades the
node. Commit the bump. If you must test it live first, suspend the root and the child, as two
calls, before you apply:

1. Run `mise run //kube/clusters/frostlink:suspend-ks flux-system flux-system`.
2. Run `mise run //kube/clusters/frostlink:suspend-ks system-upgrade tuppr-upgrades`.

The full sequence is in `commit-style.md` § Frostlink.

### Break-glass: manual upgrade

Use this only when tuppr is not available. Note that it uses the legacy
`factory.talos.dev/installer/` path. tuppr uses `metal-installer`.

```bash
mise run //kube/clusters/frostlink/talos:upgrade <version>   # reboots with --reboot-mode powercycle, 10m timeout
mise run //kube/clusters/frostlink/talos:schematic-id        # recompute the schematic ID from kube/clusters/frostlink/talos/schematic.yaml
```

`mise run //kube/clusters/frostlink/talos:upgrade` resolves the schematic from
`kube/clusters/frostlink/talos/schematic.yaml` at run time. So it installs whatever is checked in at
that time. tuppr does exactly the opposite. Use the task on purpose, with the current version. Then
make sure that the node annotation is correct.

You do not need to drain or uncordon. There is a single node, and all workloads restart
automatically after the reboot.

## Kubernetes Upgrade — break-glass only

tuppr's `KubernetesUpgrade` owns this. `kubectl get kubernetesupgrades --context frostlink` shows its
current and target version. The normal path is to bump the CR. Use the command below only when
tuppr is not available. If the CR still names the old version, expect the next Flux reconcile to
undo your work.

```bash
talosctl --talosconfig kube/clusters/frostlink/talosconfig upgrade-k8s \
  --to <k8s-version> \
  -n 10.0.0.203
```

## Node Health

```bash
talosctl --talosconfig kube/clusters/frostlink/talosconfig health -n 10.0.0.203
talosctl --talosconfig kube/clusters/frostlink/talosconfig dmesg -n 10.0.0.203 | tail -30
talosctl --talosconfig kube/clusters/frostlink/talosconfig version -n 10.0.0.203
talosctl --talosconfig kube/clusters/frostlink/talosconfig get machineconfig -n 10.0.0.203 -o yaml
```

## Known OCI / Talos Quirks

- NTP: `TimeSyncConfig` `ntp.servers: [169.254.169.254]`. This is the link-local NTP of the OCI
  metadata service.
- hostDNS: `ResolverConfig` with `forwardKubeDNSToHost: true, resolveMemberNames: true`. Pod DNS
  goes to the host, and node names resolve inside pods.
- Cilium on Talos/OCI: the Cilium HelmRelease requires `sysctlfix.enabled: false`. Talos has no
  `/etc/sysctl.d/`. Without the setting, the cilium-agent init crashes.
- The `tailscale` extension creates `tailscale0` (MTU 1280). That is why Cilium pins `devices` and
  `MTU` (`oci-networking.md` § cilium `devices` and `MTU` are pinned, which wins). If you change or
  replace the tailscale patch, Cilium needs no change. If you add another host interface that pods
  must route over, Cilium does need a change.
- The Talos `clusterName` (`frostlink`) is not the cluster name of Cilium. The Talos name comes from
  `talosctl gen config frostlink` and names the Kubernetes cluster. The Cilium name
  (`frostlink-vps`, ID 2) is set only in the Cilium HelmRelease. It is a leftover from the removed
  ClusterMesh. See `oci-networking.md` § cilium cluster identity.

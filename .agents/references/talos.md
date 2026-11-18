# Reference: Talos — home-infra

## Running Versions

Anything in this file that names `v1.14.0-beta.1` describes a bug seen on that build. This file
records no re-test on a later build. Treat the bug as still present until a test on one node
(`diff-node`, then `talosctl get staticpods`) shows otherwise.

This file does not give the versions. The places below hold the version, and they must move
together. Read them. Do not trust a doc:

```bash
kubectl get nodes -o wide                      # live Talos + kubelet version
grep -n installer kube/clusters/artemis/talos/cluster.yaml.j2        # installer image in git
grep -rn version kube/clusters/artemis/apps/system-upgrade/tuppr/upgrades/   # both tuppr CRs
grep -n '^talos' .mise/config.toml             # talosctl pin
```

`talosctl` decodes configuration documents on the client. A client that is older than the
cluster rejects a v1.14 document (`"KubeTalosAPIAccessConfig" "v1alpha1": not registered`) before the node sees it.
So always run `talosctl` from inside this repo. There, the mise shim resolves the pinned version.
If you run it from somewhere else, you get the global install, which is older. You do not need a
`mise exec --` wrapper. The shims are on PATH through `~/.zshenv`. They resolve the repo pin from
the working directory, in non-interactive `sh` too.

## Config Management

```bash
mise run //kube/clusters/artemis/talos:render-config <node>     # render node config from template
mise run //kube/clusters/artemis/talos:validate [node]          # render + talosctl validate; all nodes if omitted, exits non-zero on failure
mise run //kube/clusters/artemis/talos:diff-node <node>         # apply-config --dry-run: what would change on that node
mise run //kube/clusters/artemis/talos:apply-node <node>        # apply config to node (live, no reboot)
```

Run `validate` after you edit a template. Run `diff-node` before `apply-node`. An empty
`diff-node` on all nodes is the proof that the cluster and git agree.

`render-config` layers three Jinja2 templates through `talosctl machineconfig patch`:

1. `kube/clusters/artemis/talos/cluster.yaml.j2`. It holds everything that every node shares.
2. `kube/clusters/artemis/talos/<controlplane|worker>.yaml.j2`. `machine.type` in the node file
   selects it (`mise run //kube/clusters/artemis/talos:machine-type`). That is why every node file
   must declare `machine.type`.
3. `kube/clusters/artemis/talos/nodes/<node>.yaml.j2`. It holds the hostname, the labels and the
   install disk.

A patch to the v1alpha1 document merges per struct field, and some structs are leaves.
`PEMEncodedCertificateAndKey` is one. A patch that sets only `ca.key` replaces the whole pair and
renders `crt: ""`. The result is a control plane with no CA certificate, and it validates clean.
Always put `crt` and `key` together in the file that sets either one. Typed documents (`kind:`)
merge by kind + `name`, so partial overrides there are safe.

`cluster.yaml.j2` defines the installer image once, in its `UnattendedInstallConfig`, as
`factory.talos.dev/installer/{{ ENV.SCHEMATIC }}:<version>`. `render-config` derives the schematic
type from the node name, resolves it against the Image Factory, and injects the ID. The mapping
lives in `kube/clusters/artemis/talos/mise.toml` § `schematic-type`:

| Node name pattern | Schematic      |
| ----------------- | -------------- |
| `*-cp-*`          | `controlplane` |
| `*-gpu-*`         | `gpu`          |
| `ymir`            | `metal`        |
| anything else     | `worker`       |

### `metal` and `controlplane` resolve to the SAME factory ID

`kube/clusters/artemis/talos/schematics/metal.yaml` and
`kube/clusters/artemis/talos/schematics/controlplane.yaml` have identical content today. They have
the same seven extensions and the same kernel args, so the Image Factory returns one ID for both.
The control planes and `ymir` show the same ID in the node annotation
`extensions.talos.dev/schematic`. The command in § Extension Changes prints the annotation of
every node.

Never copy an ID from a node into a manifest. Resolve it with
`mise run //kube/clusters/artemis/talos:schematic-id <type>`. That task POSTs the schematic file to
the Image Factory.

This has two consequences that are not obvious:

- You cannot tell `ymir` from a control plane by its annotation. Do not use the schematic ID that a
  node reports to find which schematic _file_ the node tracks. Use
  `mise run //kube/clusters/artemis/talos:schematic-type <node>`. It is the only authority.
- A change to `controlplane.yaml` alone silently changes `ymir` too. The reverse is also true. Both
  files hash to one ID until their contents differ. When one file gets an extension that the other
  does not have, the IDs split, and `ymir` starts to track its own image. That is intended. Expect a
  "control-plane-only" schematic edit to reboot the bare-metal worker as well.

`metal` is `worker` minus `siderolabs/qemu-guest-agent`. On bare metal, that service can never
come up. Talos blocks its boot sequence while it waits for the service. When the phase times out,
the node reboots, about every 70 minutes. Bare-metal workers must get `metal`, never `worker`.
Node files never carry an installer image or a schematic hash. That pattern let `schematics/controlplane.yaml` silently drift away from what the CP
nodes ran.

## Extension Changes

An extension change needs a new schematic ID and a node reboot. The render computes the ID, so you
update nothing by hand:

1. Edit the schematic in
   `kube/clusters/artemis/talos/schematics/<controlplane|worker|gpu|metal>.yaml`. There are four
   files, not three. People usually forget `metal.yaml`.
2. Run `mise run --yes //kube/clusters/artemis/talos:apply-node <node> --mode=reboot`.

To see the image that a node will get, without an apply, run
`mise run //kube/clusters/artemis/talos:machine-image <node>`.

A schematic change at the same Talos version leaves a boot-order trap:

- Talos writes the new UKI as `Talos-<version>~N.efi` beside the original `Talos-<version>.efi`
  (`sdboot.go:generateNextUKIName()`).
- The `strverscmp_improved` function of systemd-boot treats `~` as an rpm-style pre-release marker.
  So `~N` sorts below the plain name. The sort is descending, so the stale original is
  `entries[0]`.
- Our `loader.conf` carries only `timeout 10` and no `default`. So a correct boot depends entirely
  on the `LoaderEntryDefault` NVRAM variable.
- When that variable does not resolve, sd-boot falls through to the stale image.

The naming of Talos itself makes its newest image look older than the image that it replaced.

Symptom when the node lands on the stale image: the node booted without the `drbd` extension. Every
miroir PVC on it hangs in Init (`diskless leg not realized`). The agent log says `Module drbd not
found in directory /lib/modules/…-talos`.

A Talos version upgrade clears the trap by itself. It writes a plain-named UKI for the new version.
It keeps only that UKI and the previous version, so no `~N` pair survives
([#2763](https://git.dcunha.io/Exikle/home-infra/issues/2763)). The trap comes back after any
same-version schematic change. After the next reboot of a node that had a schematic change,
compare what it runs with what it must run (the commands below).

Nothing else reports the trap:

- The `installer.image` of the machine configuration stays correct.
- `unattendedinstallstatuses` says `phase: installed`.
- tuppr says Completed. It keys on the version, not on the schematic.
- The node is `Ready`.

Before and after you reboot a node for any reason, compare what it runs against what it must run:

```bash
kubectl get nodes -o json | jq -r '.items[].metadata | "\(.name) \(.annotations["extensions.talos.dev/schematic"][0:12]) drbd=\(.labels["extensions.talos.dev/drbd"] // "-")"'
mise run //kube/clusters/artemis/talos:schematic-id worker          # or controlplane / gpu / metal
talosctl -n <ip> get bootedentries      # which ESP entry actually booted
```

To fix a mismatch, run `mise run --yes //kube/clusters/artemis/talos:upgrade-node <node>`. The task
runs a same-version `talosctl upgrade` with the rendered machine image and `-m powercycle`. Only an
upgrade writes an image to disk. `apply-node --mode=reboot` changes the configuration and reboots,
but it does not reinstall.

The talos tasks pass the hostname to `talosctl`, so they need LAN or Headscale DNS. Public DNS has
no record for the short names. Off the LAN, run the read-only `talosctl` calls in this section by
node IP.

When you diagnose this, read the boot variables directly. They persist correctly, so you can trust
the values:

```bash
G=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
talosctl -n <ip> read /sys/firmware/efi/efivars/LoaderEntryDefault-$G | tail -c +5 | iconv -f UTF-16LE
talosctl -n <ip> read /sys/firmware/efi/efivars/LoaderEntries-$G      | tail -c +5 | iconv -f UTF-16LE
```

The ESP itself is `/dev/vda1`, and Talos does not keep it mounted at runtime. On a VM, you can
inspect it from `pantheon` while the guest runs. Mount it `ro`. Write to it only while the guest is
stopped:

```bash
mount -o ro /dev/zvol/vmpool/vm-<vmid>-disk-0-part1 /mnt/esp && ls -la /mnt/esp/EFI/Linux/
```

Nobody knows yet why `LoaderEntryDefault` does not resolve on some nodes and does resolve on
others. Upstream `siderolabs/talos#14146` is the closest match.

## Config Format (Talos 1.14 multi-document)

The templates use the 1.14 typed-document layout. Everything that is still in v1alpha1 is there for
a concrete reason. The team audited it against the full 1.14 document catalogue on 2026-08-03. Do
not "finish" the migration without a new check against the 1.14 stable reference:

| Stays in v1alpha1                                    | Why                                                                                                                                                                                                  |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `machine.token`, `machine.ca`, `machine.type`        | No document equivalent exists. Only the _Kubernetes_ CAs got documents, not the machine CA.                                                                                                          |
| `machine.features.diskQuotaSupport`                  | No document exists. The upstream `VolumeConfig` reference says: "project quota support is configured via machine features". This is not an oversight. Do not look for a `VolumeConfig` field for it. |
| `cluster.etcd`                                       | No etcd document exists at all in 1.14. The config reference has no `etcd/` group. `advertisedSubnets` and `extraArgs` have nowhere else to live.                                                    |
| PKI (`cluster.ca`, `aggregatorCA`, `serviceAccount`) | The new CA documents parse PEM. The 1Password items hold base64-DER, as v1alpha1 expects.                                                                                                            |
| `cluster.clusterName`, `cluster.controlPlane`        | `KubeClusterConfig`. See the DO-NOT-MIGRATE warning below. This one caused an outage.                                                                                                                |

Discovery is on. `DiscoveryServiceConfig` (endpoint `discovery.talos.dev`) and
`DiscoveryIdentityConfig` moved `cluster.id` and `secret` out of v1alpha1. They register every node
with the public discovery service. That service fills `talosctl -n <ip> get members` (all seven
nodes). It also lets workers find all three control planes, so they do not depend on the endpoint
alone. The Kubernetes registry has no document at all.

`machine.install` is `UnattendedInstallConfig`. The controller "mirrors the legacy .machine.install
install behavior", but it stops early on `Machine().Installed()`. So the document does nothing on a
provisioned node. It acts only on a machine that booted from the ISO in maintenance mode. Legacy
`diskSelector.model` globs and bare `disk:` paths became CEL
(`disk.model == "..." && disk.transport == "sata"`, `disk.dev_path == "/dev/vda"`). § tuppr rebuilds
explains the image path prefix.

The templates have no comments. Every "why" for them is in this section. If a line in
`kube/clusters/artemis/talos/*.j2` looks redundant or wrong, it is almost certainly listed below.
Read this section before you delete it.

These caused real downtime when done wrong:

- Never migrate `.cluster.controlPlane` to `KubeClusterConfig` on 1.14.0-beta.1. If you remove it,
  the field is nil. The v1alpha1→k8s bridge still calls `(*ClusterConfig).Endpoint()` unguarded
  from `K8sServiceAccountConfig()` (`v1alpha1_k8s_bridge.go:331` → `v1alpha1_clusterconfig.go:66`).
  That panics `secrets.RootKubernetesController`, which then stops rendering the control plane
  static pods. Every CP comes back from a reboot with no kube-apiserver. This took the whole API
  down on 2026-08-03. The node stays Ready, so the fault shows only on reboot. Make sure with
  `talosctl get staticpods`.
    - Consequence: `cluster.yaml.j2` sets the worker endpoint and `controlplane.yaml.j2` overrides
      it. So `.cluster.controlPlane` is never absent from a rendered configuration.
- Disabled components still need an explicit `image:`. In 1.14.0-beta.1, `images.List()` calls
  `mustParseTag` on every component, with no condition. `KubeProxyConfig` and `KubeCoreDNSConfig`
  with `enabled: false` and no `image:` give `""` and panic-loop
  `k8s.ControlPlaneBootstrapManifestsController`. That also stalls the manifests that the
  controller always renders: CSR approve/renew RBAC, the kubelet bootstrap token,
  kube-config-in-cluster, `system:talos-nodes` and the `serviceaccounts.talos.dev` CRD. The values
  are the Talos defaults, so nothing is pulled. The components stay disabled (kube-proxy → Cilium,
  CoreDNS → our own `kube-system/coredns` HelmRelease). A Ready cluster hides this fault. Read
  `talosctl dmesg`.
- `nodeIP` must be in `KubeNodeConfig`, never in `machine.kubelet.nodeIP`. If you set both, Talos
  gives an error.
- If you use `KubeAPIServerConfig`, then `KubeAuthorizerConfig` (Node + RBAC) is mandatory.
  Without it, kube-apiserver exits with "authorizers: Required value: at least one authorization
  mode must be defined".
- `KubeAPIServerConfig` also makes `KubeAuthenticationConfig` mandatory. Without it, Talos writes
  an empty authentication-config.yaml, and the apiserver dies on "Object 'Kind' is missing".
- `KubeNodeConfig.taints: {}` replaces `.cluster.allowSchedulingOnControlPlanes: true`. It must be
  an empty map. A list does not decode. 1.14 lists the controlplane NoSchedule taint explicitly
  instead of a default, and this cluster runs workloads on the CPs.
- The `KubeEtcdEncryptionConfig` secretbox key must keep the name `key2`. The name is part of the
  ciphertext prefix of every encrypted secret. If you rename it, the existing secrets cannot be
  decrypted.
- No `KubeFlannelCNIConfig` document is the new form of `cluster.network.cni.name: none`.

Quieter ones:

- There is no `TimeSyncConfig` document, on purpose. Talos always emits a `default` layer time
  server (`constants.DefaultNTPServer` = `time.cloudflare.com`) with `useNTS: true`. `useNTS`
  defaults to true only when no NTP configuration exists at all. If you write an explicit
  `TimeSyncConfig` without `useNTS: true`, it silently _disables_ NTS. The UCG-Max at 10.10.99.1 does not run an NTP
  daemon (UDP/123 returns connection refused) and does not send DHCP option 42. So it was only ever
  a dead first entry. NTS also needs hostnames, not IPs, so that entry was not possible anyway.
  Make sure with `talosctl get timeserverspecs --namespace network-config` (it shows the layers). Look for
  "established NTS session" in `dmesg`. Layer precedence: default → cmdline → platform → operator
  (DHCP) → configuration.

- You must set `SecurityProfileConfig.workloadIsolation: true` explicitly. 1.14 turns it on by
  default for new clusters only. Upgraded clusters (this one) keep shared namespaces until the
  document exists. An apply restarts CRI, kubelet and all pods, with no reboot. The documented
  casualty is the in-tree iSCSI volume plugin. We use miroir (DRBD) and in-tree NFS, and neither
  needs a host daemon.
- `KubeTalosAPIAccessConfig` has no `enabled` field. The document turns it on by being present.
- `disableManifestsDirectory` is deliberately absent. v1alpha1 marks it "locked to true in
  multi-doc config", so you do not need it and cannot set it. It was the last thing that held the
  kubelet block in v1alpha1. `extraConfig` is spelled `config` on `KubeletConfig`.
- `machine.features.rbac` and `apidCheckExtKeyUsage` no longer exist in the 1.14 v1alpha1 schema.

`KmsgLogConfig` is adopted. `cluster.yaml.j2` defines `kmsg-to-victorialogs`, which ships kernel
logs to the `observability/talos-logs` receiver at `tcp://127.0.0.1:5170/`
(`grep -n -A2 KmsgLogConfig kube/clusters/artemis/talos/cluster.yaml.j2`).

## 1.14 Documents Considered and NOT Adopted

These came from the same audit as § Config Format (Talos 1.14 multi-document). They are deliberate
omissions, not gaps. It is cheaper to read this list again than to find out again why each was
skipped:

| Document                                           | Why not                                                                                           |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `TimeSyncConfig`                                   | Writing it disables NTS. See the note above.                                                      |
| `KubeClusterConfig`                                | nil-deref outage on beta.1                                                                        |
| `OOMConfig`                                        | The 1.14 userspace OOM handler, driven by CEL trigger and ranking expressions. Not evaluated yet. |
| `EventSinkConfig`                                  | It can ship Talos events to VictoriaLogs over tcp/udp. Useful here, but not wired up yet.         |
| `KubeSpanConfig`                                   | One site. No mesh needed.                                                                         |
| `RegistryMirrorConfig` / `ImageCacheConfig`        | No pull-rate or bandwidth problem to solve.                                                       |
| `SwapVolumeConfig` / `ZswapConfig`                 | No swap on these nodes, by design.                                                                |
| `UserVolumeConfig`                                 | No local-path storage. Everything is miroir or NFS.                                               |
| `NetworkRuleConfig` / `NetworkDefaultActionConfig` | Host firewall. Not attempted. It needs care, so that it does not lock out the API.                |

## kata-containers — provisioned but unused

Do not opt a workload in. Kata was tried on this cluster and did not work
([#2761](https://git.dcunha.io/Exikle/home-infra/issues/2761), closed).

All four schematics still ship `siderolabs/kata-containers`. A `kata-qemu`
RuntimeClass exists in the cluster. No pod uses it. Nothing in `kube/clusters/artemis/talos/`
wires a containerd runtime handler for it, because the extension supplies its own.

The removal of the extension needs its own issue. A removal from a schematic is a schematic change
that needs reboots. The tuppr guard assumes that each new schematic is a superset of the running
one (§ tuppr rebuilds from the node's RECORDED schematic).

How the opt-in works, for reference only:

- A pod opts in with `runtimeClassName: kata-qemu`. Each such pod runs in its own lightweight VM,
  so it needs `/dev/kvm`. All seven nodes expose it. The Proxmox workers expose it through nested
  virtualization.
- The extension registers the `kata-qemu` containerd runtime handler on every node itself.
- `kube/clusters/artemis/apps/kube-system/kata-containers/` only declares the RuntimeClass and its
  `overhead.podFixed`.

## `kube-system/bootstrap-token-*` is Talos-managed — do not delete it

Talos renders a `bootstrap.kubernetes.io/token` Secret in `kube-system` that never expires. It is
not a stale credential. It has these properties:

- Its date is the cluster-init day.
- It has `usage-bootstrap-authentication: "true"` and
  `auth-extra-groups: system:bootstrappers:nodes`.
- It has no `expiration` field.

Talos builds it from `cluster.token` in the machine config (`op://infrastructure/talos/CLUSTER_TOKEN`,
`<id>.<secret>`). The id becomes the suffix of the Secret name and `token-id`. The secret becomes
`token-secret`. The template is `k8stemplates/kubelet.go` in siderolabs/talos. It has no
`expiration` key at all, so the token is permanent by design. Kubelet TLS bootstrap uses it when a
node joins or joins again. If you delete it, node join breaks until Talos renders it again. To
rotate it, rotate `cluster.token` on every node. Do not edit the Secret.

No RoleBinding points at it, because the bootstrap authenticator of the apiserver uses it directly.
No RBAC is not evidence that a bootstrap token is unused.

## Automated Upgrades — owned by tuppr

`tuppr` runs in the `system-upgrade` namespace. It owns both Talos and Kubernetes upgrades.
Upgrades are declarative. Edit the version in
`kube/clusters/artemis/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` (or
`kubernetesupgrade.yaml`) and merge. tuppr then rolls the cluster. Do not upgrade a node by hand
while tuppr is healthy.

Configuration (`kube/clusters/artemis/apps/system-upgrade/tuppr/upgrades/`):

| Setting                     | Value                                                                          | Why                                                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `TalosUpgrade.version`      | read from the CR, not from here                                                | Renovate tracks it through `custom.talos-factory`. Automerge is OFF.                                                   |
| `policy.rebootMode`         | `powercycle`                                                                   |                                                                                                                        |
| `policy.timeout`            | `45m`                                                                          | The 30m default was too short. factory.talos.dev bakes installer images on the first request, which stalls a pre-pull. |
| `drain.enabled`             | `true`                                                                         | Seven nodes, so a drain has somewhere to go. Frostlink has nowhere.                                                    |
| Talos health gates          | Node `Ready`, kopiur `Snapshot` not Pending/Running, `MiroirNodeGroup` healthy | Never roll the next node onto degraded miroir storage.                                                                 |
| `KubernetesUpgrade.version` | read from the CR, not from here                                                |                                                                                                                        |
| K8s health gates            | kopiur `Snapshot` idle, `MiroirNodeGroup` healthy                              | Stricter than the Talos gate. A K8s upgrade has no reboot to excuse a WARN.                                            |

### tuppr rebuilds from the node's RECORDED schematic

tuppr rewrites `.machine.install.image` to `factory.talos.dev/installer/<schematic>:<version>`. It
uses the schematic that the node reports at runtime, not the schematic in
`kube/clusters/artemis/talos/schematics/`. So extensions survive an upgrade with no repo change. It
also means that a stale recorded schematic silently installs again an extension that you removed
from git. The removal of an extension takes two steps:

1. Edit the schematic file.
2. Run `mise run --yes //kube/clusters/artemis/talos:apply-node <node> --mode=reboot`. The node then
   records the new ID _before_ the next tuppr run.

If you edit only the schematic file, nothing changes in what tuppr installs.

The image path stays `installer/`, not the upstream `metal-installer/`, because the tuppr
`factory-url` annotation pins the same prefix. Both must move together. The tuppr of Frostlink uses
`metal-installer`. The two clusters are deliberately not aligned here.

To override the schematic guard, you need both tuppr annotations on `KubeNodeConfig`.
`buildTalosUpgradeImage` reads `tuppr.home-operations.com/schematic` only inside its `factory-url`
branch. So that annotation alone does nothing. The override is safe only because each new schematic
here is a superset of the running one. Read this again before a schematic removes an extension.

tuppr triggers on `currentVersion != targetVersion`. It is not a "newer than" check, and there is
no downgrade guard. Never bump a version out of band while Flux still serves the old value from
git. The next reconcile reverts the CR, and tuppr downgrades the cluster.

## Node Reference

Node files are the ground truth: `ls kube/clusters/artemis/talos/nodes/`. Anything that counts
nodes, such as a tuppr blast-radius argument or a drain plan, must count from that list. `ymir` is
a bare-metal worker and the only node on the `metal` schematic. The IPs are in
`kubectl get nodes -o wide`. The hardware is in `hardware.md`.

# Pod Security Exceptions — home-infra

`cluster-conventions.md` § Helm / app-template defines the default security context for every
app, and it wins. A few apps cannot run under it. This file records the reason for each
deviation. The manifests carry no comments (`yaml-conventions.md` § No Comments in Manifests). If
a deviation has no recorded reason, someone will "fix" it back to the default and break the app.

This file covers Artemis and `kube/base/`. The tree gives the current set, not a list here:

```bash
grep -rlnE 'runAsNonRoot: false|readOnlyRootFilesystem: false|runAsUser: 0\b|privileged: true|hostNetwork: true|hostPID: true|allowPrivilegeEscalation: true|^\s+add:' kube/clusters/artemis/apps/ kube/base/
```

The command also lists files that are not pod security contexts (for example a `recyclarr.yml`
payload and an `agentgatewaypolicy.yaml`). Read each hit. `kube-system/cilium` and
`observability/node-exporter` use the upstream chart settings, so they have no row.

## Why each one deviates

| App                               | Deviation                                                                                                                                               | Reason                                                                                                                                                                                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `home-automation/matter-server`   | the route-fix init container runs uid 0 with `NET_ADMIN`. The app (uid 1000) adds `NET_RAW` and sets `net.ipv4.ping_group_range: 1000 1000`             | Init: the same as the init container of home-assistant. App: upstream `setcap`s `ping` with `cap_net_raw+ep`, so exec fails with EPERM when `NET_RAW` is dropped. The sysctl lets it ping over a datagram socket                                   |
| `default/bambuddy`                | the app (uid 1000) adds `NET_BIND_SERVICE`                                                                                                              | The upstream image runs `setcap cap_net_bind_service=+ep` on `python3`, which runs the whole app. The matter-server row shows that exec of such a binary fails with EPERM when the capability is dropped. This failure was not tested for bambuddy |
| `forgejo/buildkit`                | uid 1000, `allowPrivilegeEscalation: true`, `readOnlyRootFilesystem: false`, `SETUID`/`SETGID` added, `seccompProfile: Unconfined`, AppArmor unconfined | rootless buildkitd unshares user namespaces. See `ci.md` § buildkit                                                                                                                                                                                |
| `forgejo/forgejo-runner`          | the `dind` sidecar of the `podspec-dind` job template is `privileged: true`                                                                             | It runs dockerd for the workflows that need Docker. See `ci.md` § The runner                                                                                                                                                                       |
| `kube-system/lldpd`               | uid/gid 0, `hostNetwork: true`, adds `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `NET_ADMIN`, `NET_RAW`, `SETGID`, `SETPCAP`, `SETUID`, `SYS_CHROOT`             | It runs on the host network to speak LLDP on the interfaces of the host                                                                                                                                                                            |
| `home-automation/home-assistant`  | the route-fix init container runs uid 0 with `NET_ADMIN`                                                                                                | It deletes the `eth0` (Cilium) IPv6 nexthop. See `networking.md` § IoT pods drop the Cilium IPv6 default route. The app container keeps the default                                                                                                |
| `kube-system/etcd-defrag`         | uid/gid 60, `hostNetwork: true`, control-plane only                                                                                                     | It reaches etcd on `127.0.0.1:2379` with the certs in `/system/secrets/etcd`, which Talos owns as the etcd user (uid 60). Root without `DAC_OVERRIDE` gets permission denied on them                                                               |
| `observability/talos-logs`        | `hostNetwork: true`                                                                                                                                     | Talos ships kernel logs to `tcp://127.0.0.1:5170/` on each node (`talos.md`, `KmsgLogConfig`). Only a receiver in the network namespace of the host can listen on that address                                                                     |
| `observability/blackbox-exporter` | adds `NET_RAW`                                                                                                                                          | Its `icmp` module uses the ICMP prober, which needs a raw socket                                                                                                                                                                                   |
| `observability/drm-exporter`      | adds `PERFMON`                                                                                                                                          | See `gpu.md` § drm-exporter                                                                                                                                                                                                                        |

Anything that deviates and is not in this table is drift. Add a row when you add an exception, and
say what actually breaks under the default. "Needs root" without the failure mode is not a reason.

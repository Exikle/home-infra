# Frostlink — Agent Context

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free Ampere A1 (ca-toronto-1), managed with Flux CD.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecrets (no SOPS)
- **Domain**: `frostlink.dev` | **Repo**: <https://git.dcunha.io/Exikle/frostlink>
- **CNI**: Cilium | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute via Cloudflare tunnel)
- **Inbound**: no longer zero — the towonel edge listens directly on 443/tcp + 51820/udp

---

## Repo Structure

```text
.agents/          # AI agent instructions, references, and skills
talos/            # Talos schematic and patches
bootstrap/        # helmfile.d/ and resources.yaml.j2 for one-time bootstrap
kubernetes/
  apps/           # App HelmReleases by namespace
  components/     # Reusable Flux Components (postgres/cert, kopiur, anubis, alerts)
  flux/sync/      # Entrypoint Kustomization → kubernetes/apps
```

---

## Hardware

### Frostlink Node (Oracle Cloud)

- **VM.Standard.A1.Flex** — 4 OCPU / 24 GB RAM, ARM64 Ampere A1
- **Boot volume**: 50 GB / 10 VPU
- **Region**: ca-toronto-1, AD-1
- **Instance name**: `instance-20260612-2239`
- **Public IP**: `40.233.88.33` (reserved) — DNS detail under § Networking
- **Internal IP**: `10.0.0.203`
- **Tailscale IP**: `100.67.108.103`
- **Talos version**: v1.14.0-rc.1 | **Kubernetes**: v1.36.1 (confirm with `talosctl version` / `kubectl version`)
- **Schematic**: `e7f26ff1516313fd32b377e04c573728c7c942655ecb5580e728ab92bbf4cfc1` — defined by `talos/schematic.yaml`; the node reports the same ID in its `extensions.talos.dev/schematic` annotation
- **Extensions**: `iscsi-tools`, `tailscale`, `util-linux-tools`, `zfs` — **`zfs` is load-bearing**: the whole `openebs-zfs` storage layer depends on it
- **Never hand-edit the schematic ID here.** tuppr rebuilds an upgrade from the *node's* schematic, so a stale or hand-written ID silently reinstalls a removed extension — or drops `zfs` and takes storage down. Derive it: `just talos schematic-id`, or read the node annotation with `kubectl get node frostlink -o jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'`

---

## Networking

- **VCN**: `frostlink-vcn`, subnet `frostlink-public` (10.0.0.0/24)
- **DNS**: `edge.frostlink.dev` is an A record (DNS-only) for the node's public IP. `frostlink.dev` and `external.frostlink.dev` are proxied CNAMEs to the Cloudflare tunnel; there is **no** wildcard DNS record, though the cert *is* wildcard
- **Tailscale**: node joined (tag: k8s); all management access goes over the Tailscale IP listed under § Hardware
- **Security list ingress**: 443/tcp + 51820/udp (towonel), 50000/tcp (Talos API), 22/tcp (dead — no SSH on Talos), ICMP. 8443/tcp and 80/tcp deliberately closed; 6443/tcp removed 2026-08-18. Full detail in `.agents/references/networking.md`
- **kubeconfig**: `.mise.toml` pins `KUBECONFIG={{config_root}}/kubeconfig` (and `TALOSCONFIG` alongside it), so **inside this repo the repo-local kubeconfig wins over `~/.kube/config`** and no `kubectx`/`--context` step is needed. Context `frostlink`, server `https://100.67.108.103:6443`. See `.agents/instructions/tooling.md` § kubectl and talosctl scoping

---

## Namespaces

| Namespace          | Purpose                                                                        |
| ------------------ | ------------------------------------------------------------------------------ |
| `cert-manager`     | cert-manager, ACME ClusterIssuer, cert-manager CSI driver, internal Postgres CA, trust-manager |
| `cnpg-system`      | CloudNativePG operator + barman-cloud plugin                                   |
| `database`         | Shared CNPG Postgres `Cluster` + pgbouncer `Pooler`, shared Dragonfly          |
| `default`          | Empty by design — nothing is deployed here                                     |
| `dragonfly-system` | Dragonfly operator                                                             |
| `external-secrets` | External Secrets Operator + 1Password Connect                                  |
| `fediverse`        | GoToSocial, phanpy, apoci (OCI registry), fingerjoin                           |
| `flux-system`      | flux-operator, flux-instance, flux-webhook, konflate                           |
| `kopiur-system`    | Kopiur backup controller + the `r2` ClusterRepository (Cloudflare R2)          |
| `kube-system`      | Cilium, CoreDNS, k8tz, ksgate, metrics-server, reloader                        |
| `matrix`           | continuwuity, mautrix-signal, mautrix-whatsapp                                 |
| `network`          | Envoy Gateway, wildcard certificates, cloudflare-tunnel, cloudflare-dns        |
| `observability`    | VictoriaMetrics stack (vm-single/operator/alert/scrapes), alertmanager, node-exporter, kube-state-metrics, kromgo, gatus, chaski |
| `openebs-system`   | zfs-localpv CSI — provides the default `openebs-zfs` StorageClass              |
| `system-upgrade`   | tuppr — Talos and Kubernetes upgrade controller                                |
| `tools`            | atuin                                                                          |
| `towonel`          | towonel hub + edge — tunnel for other machines. Its own `privileged` namespace because of `hostNetwork` |

App and version lists rot — Renovate moves them and nothing here follows. For the current apps in
a namespace run `ls kubernetes/apps/<namespace>/`; for a live version read the app's own
`ocirepository.yaml`/`helmrelease.yaml`, or ask the cluster.

---

## Bootstrap Order

Bootstrap uses helmfile (not `flux bootstrap`) because the Forgejo repo must already have content before Flux GitRepository can sync. See `.agents/references/bootstrap.md` for full detail.

1. Import Talos custom image → launch VM.Standard.A1.Flex (4 OCPU / 24 GB, 50 GB boot)
2. Attach reserved public IP; ensure security list allows 50000/tcp
3. `talosctl gen config` with patches → `talosctl apply-config --insecure` → `talosctl bootstrap`
4. Export kubeconfig: `talosctl kubeconfig`
5. Apply bootstrap secrets: `KUBECONFIG=... just bootstrap base`
   - Requires 1Password items: `1password-frostlink`, `forgejo-frostlink`, `cloudflare-frostlink`
6. Run `just bootstrap cni` — installs cilium, coredns, cert-manager directly via `helm upgrade --install` (NOT via helmfile — SSA conflict); reads chart/version/values straight from each app's `ocirepository.yaml`/`helmrelease.yaml`
7. Run `just bootstrap apps` — installs external-secrets → onepassword-connect → flux-operator → flux-instance
8. Commit and push repo to Forgejo → Flux reconciles everything from Git
9. Deploy `network` namespace **first** (cert-manager clusterissuer → envoy-gateway → certificates → cloudflare-tunnel) before any app with an HTTPRoute

---

## Known Quirks

- **Single node**: control plane also acts as worker (`allowSchedulingOnControlPlanes: true`)
- **OCI DNS**: `169.254.169.254` is the only working upstream for CoreDNS. `/etc/resolv.conf` resolves to `127.0.0.53` (unreachable inside pods). Set `forward . 169.254.169.254` in CoreDNS values.
- **Cilium on Talos/OCI**: must set `sysctlfix.enabled: false` — Talos has no `/etc/sysctl.d/`; cilium-agent init crashes otherwise.
- **Helm v4 SSA conflicts**: Talos pre-installs cilium and coredns with field manager `helm-controller`. Helmfile also uses `helm-controller`. `just bootstrap cni` installs cilium, coredns, and cert-manager with direct `helm upgrade --install` calls to avoid conflicts.
- **`helmfile --cleanup-on-fail`**: deletes cluster-scoped resources on failure, leaving orphaned SSA ownership that conflicts on retry.
- **`talosctl patch machineconfig --patch`**: expects a DELTA patch (only changed fields). Passing a full config duplicates array fields (e.g. `machine.files`) and breaks the node on next boot. Use a minimal patch file, or `talosctl apply-config --file` for full replacement.
- **Forgejo auth via HTTPS**: SSH unreachable from OCI. Flux uses HTTPS with secret `flux-system/flux-system` (`username` + `password` fields).
- **certSANs for Tailscale**: apply with a 6-line minimal patch — never include the full `controlplane.yaml` as a patch.
- **PodSecurity + hostNetwork**: `network` has no PSS label so it inherits `baseline`, which forbids hostNetwork and hostPorts. towonel therefore lives in its own `privileged` namespace rather than relaxing `network`.
- **CSINode topology keys go stale**: tuppr labels the node `tuppr.home-operations.com/upgrading` during an upgrade. If the node reboots while that label is set, zfs-localpv bakes it into CSINode's `topologyKeys`; once tuppr removes the label the capacity controller can build **0 topology segments**, publishes no `CSIStorageCapacity`, and then **no new PVC can schedule anywhere** ("node(s) did not have enough free storage" with a pool that is 90% free). Fix: `kubectl -n openebs-system rollout restart ds/zfs-localpv-node` then `deploy/zfs-localpv-controller`.
- **flate `dependsOn` namespace**: `just kube apply-ks` uses flate, which resolves dependencies by `targetNamespace`. Cross-namespace refs require `namespace: <targetNamespace>` (e.g. `namespace: cert-manager` for clusterissuer, `namespace: external-secrets` for onepassword-connect). Without it, flate looks in the current ks's own targetNamespace and fails.

---

## Agent Instructions

Read `.agents/instructions/` before working in this repo — all five are auto-loaded via `CLAUDE.md`:

| File                     | Contents                                                            |
| ------------------------ | ------------------------------------------------------------------- |
| `tooling.md`             | Critical rules, `just` commands, kubectl scoping, MCP server tiers, subagent notes |
| `cluster-conventions.md` | App structure, app-template v5, secrets pattern, storage, database onboarding |
| `yaml-conventions.md`    | Field ordering, YAML sorting, and the no-comments-in-manifests rule |
| `commit-style.md`        | Commit workflow, signing identities, squash rules, safety rules     |
| `session.md`             | Session journal format, when to write entries, memini usage         |

## References

Read `.agents/references/` for topic-specific detail (load only what is relevant):

| File               | Contents                                                                |
| ------------------ | ----------------------------------------------------------------------- |
| `anubis.md`        | Anubis PoW scraper deterrence — component, GoToSocial policy, caveats   |
| `bootstrap.md`     | Bootstrap order and one-time setup                                      |
| `database.md`      | Shared Postgres, pgbouncer tuning, CNPG PKI gotchas, surviving a primary restart |
| `flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race           |
| `networking.md`    | Gateways, OCI VCN rules, Cloudflare tunnel, Tailscale                   |
| `renovate.md`      | Preset pinning, automerge policy, tuppr/zer0ver guards                  |
| `storage.md`       | openebs-zfs, zfs-snapshotclass, Kopiur backup component, the restore path |
| `talos.md`         | Oracle Cloud Talos config, single-node quirks, upgrade steps            |
| `towonel.md`       | towonel hub/edge — ports, grey-cloud DNS, key material, kopiur movers   |

## Skills

`.agents/skills/` holds the repeatable cluster tasks. Each `SKILL.md` carries `name:` and
`description:` frontmatter — that frontmatter is what lets an agent invoke a skill on its own,
rather than only when someone types its name. A skill added without it is invisible. See
`add-agent-content` (global).

Claude Code does not read `.agents/skills/` directly, so every skill also needs a
`.claude/skills/<name>` symlink pointing at it.

Cluster-agnostic skills live in `~/.claude/skills/` and are available in every repo, so they are
not listed here: `forgejo`, `triage-renovate`, `build-container`, `playwright`, `add-agent-content`.

| Skill                        | Natural Language Triggers                                                                          |
| ---------------------------- | -------------------------------------------------------------------------------------------------- |
| `apoci-federation/SKILL.md`  | "federate apoci", "apoci ActivityPub follow", "federation peer", "webfinger 404"                    |
| `cluster-status/SKILL.md`    | "cluster status", "what's broken", "health check", "anything down"                                  |
| `deploy-app/SKILL.md`        | "deploy X", "add app X", "set up X in namespace Y", "onboard X to the cluster"                       |
| `fix-flux/SKILL.md`          | "flux is broken", "HelmRelease stuck", "kustomization failing", "ExternalSecret not syncing"          |
| `flux-validate/SKILL.md`     | "validate manifests", "flate diff", "pre-commit check", "render kustomization"                       |
| `kopiur-restore/SKILL.md`    | "restore X from backup", "recover PVC", "roll back X's data", "kopiur restore", "the volume is empty" |
| `kubesearch/SKILL.md`        | "find examples for X", "how do others deploy X", "look up X in home-ops repos"                       |
| `restore-drill/SKILL.md`     | "backup health check", "CNPG backup status", "restore drill", "are backups working", "WAL archiving"  |
| `review-app/SKILL.md`        | "review X deployment", "audit X manifests", "check X against conventions"                            |
| `talos-ops/SKILL.md`         | "apply talos config", "upgrade talos node", "extension change", "node config change"                 |
| `towonel-ops/SKILL.md`       | "towonel is down", "create an invite", "expose X through towonel", "rotate the towonel key"           |
| `watch-deploys/SKILL.md`     | "watch the deploy", "monitor rollout", "loop watch", "/loop watch-deploys"                            |

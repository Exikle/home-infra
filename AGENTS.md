# Frostlink — Agent Context

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free (Ampere A1, ca-toronto-1),
reconciled by Flux CD. This file is the entry point for every AI agent working here, and it is
deliberately short: it holds what is true on **every** turn, plus an index of where everything
else lives.

- **Domain**: `frostlink.dev` | **Repo**: <https://git.dcunha.io/Exikle/frostlink>
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecrets, no SOPS
- **CNI**: Cilium | **Ingress**: two paths — Envoy Gateway (HTTPRoute, via Cloudflare tunnel) and the towonel edge (SNI on host `:443`, bypasses Envoy)
- **Inbound**: no longer zero — the towonel edge listens directly on 80+443/tcp and 51820/udp, plus 25565/tcp and 3000/udp on demand; Talos 50000/tcp is break-glass. Full list: `networking.md` § Oracle Cloud VCN

`ls` at the repo root is the map. Only `kubernetes/` reconciles through Flux.

---

## The rules that apply to every turn

Everything else is conditional. These are not.

1. **`main` is production, and there is one node.** No staging cluster, nothing to fail over to.
   Suspend the root **and** the target Kustomization, `just kube apply-ks`, then wait for the user
   to confirm the live deployment before committing. The full sequence is `commit-style.md`; why
   both suspends: `flux-patterns.md` § Suspend before a test-apply.
2. **Never apply cluster changes through an MCP tool — here that is worse than it sounds.** The
   MCP k8s tools do not point at this cluster at all; they point at **Artemis**. An MCP mutation
   run from this repo lands on the wrong cluster. Writes go through git, or `just kube apply-ks`
   during a test. Use local `kubectl --context frostlink`.
3. **Secrets are 1Password ExternalSecrets.** SOPS is not used here — never suggest age
   encryption or `sops --encrypt`.
4. **Cluster traffic uses `<app>.<namespace>.svc.cluster.local`**, never an external hostname.
5. **Never hand-edit the Talos schematic ID.** A stale or hand-written ID silently reinstalls a
   removed extension, or drops `zfs` and takes all storage down. Derive it: `just talos
   schematic-id` (`talos.md` § Schematic).
6. **A reboot is a full outage.** Control plane and workload are the same machine
   (`taints: $patch: delete` in `talos/patches/controlplane.yaml`). Treat `talosctl
   upgrade`/`reboot` as an outage, not a rolling operation — the destructive guard blocks them.
7. **Agents edit in a worktree, never the main checkout.** Before the first edit, run
   `just wt new <type>/<slug>` (`feat`, `fix`, `chore`, … as in commit subjects) and work only in
   the `.worktrees/<type>-<slug>` path it prints. `just wt rm <type>/<slug>` when the branch is
   merged. A pre-commit check refuses agent commits made in the main checkout.

`guard-destructive.sh` hard-blocks the destructive verbs regardless of permission mode. If you
find yourself reaching for a way around a guard, stop and hand the change back as a commit.

---

## The node

One machine, so its facts are load-bearing rather than inventory.

- **VM.Standard.A1.Flex** — 4 OCPU / 24 GB RAM, ARM64 Ampere A1, 50 GB boot volume (10 VPU)
- **ca-toronto-1 AD-1**, instance `instance-20260612-2239`
- **Public** `40.233.88.33` (reserved) · **Internal** `10.0.0.203` — the management address, reached over the Headscale site link
- **Extensions**: `iscsi-tools`, `tailscale`, `util-linux-tools`, `zfs` — **`zfs` is load-bearing**,
  the whole `openebs-zfs` storage layer depends on it
- Live versions are a command, not a number: `talosctl version --talosconfig /home/exikle/frostlink/talosconfig`, `kubectl version --context frostlink`

Management access is over the Headscale site link (`networking.md` § Access Methods). An agent's
tool calls do not get the repo-local kubeconfig, so always pass `--context frostlink` — see
`tooling.md` § kubectl and talosctl scoping. Everything else about the network — VCN, DNS records,
the security-list ingress set, the tunnel: `networking.md`.

---

## Namespaces

`ls kubernetes/apps/` is the live list; the table keeps only the _purpose_ column, which no
command recovers.

| Namespace          | Purpose                                                                  |
| ------------------ | ------------------------------------------------------------------------ |
| `cert-manager`     | ACME issuer, CSI driver, internal Postgres CA, trust bundles             |
| `cnpg-system`      | Postgres operator and its backup plugin                                  |
| `database`         | The shared Postgres cluster, its pooler, and the shared Dragonfly        |
| `default`          | Empty by design — nothing is deployed here                               |
| `dragonfly-system` | Dragonfly operator                                                       |
| `external-secrets` | Secret sync from 1Password                                               |
| `fediverse`        | Fediverse server, web client and registry                                |
| `flux-system`      | Flux controllers and the root Kustomization                              |
| `kopiur-system`    | PVC backup controller and the `r2` ClusterRepository (Cloudflare R2)     |
| `kube-system`      | CNI, DNS and cluster plumbing                                            |
| `matrix`           | Matrix homeserver and its bridges                                        |
| `network`          | Gateway, certificates, Cloudflare tunnel and DNS, Headscale              |
| `observability`    | Metrics, alerting, status page                                           |
| `openebs-system`   | zfs-localpv CSI — provides the default `openebs-zfs` StorageClass        |
| `system-upgrade`   | Talos and Kubernetes upgrade controller (tuppr)                          |
| `tools`            | Small standalone services                                                |
| `towonel`          | Tunnel hub and edge, in its own `privileged` namespace for `hostNetwork` |

---

## Known quirks

Each of these cost real time to find. The full text is in the linked doc.

- **OCI DNS**: only `169.254.169.254` works as CoreDNS upstream — `bootstrap.md` § OCI DNS — CoreDNS Forward Target
- **Cilium `sysctlfix.enabled: false`** is required on Talos — `talos.md` § Known OCI / Talos Quirks
- **Helm v4 SSA conflicts** (`helm-controller` field manager): cilium, coredns and cert-manager install with direct `helm upgrade --install` — `bootstrap.md` § Cilium / CoreDNS / cert-manager — Install Directly
- **`helmfile --cleanup-on-fail`** deletes cluster-scoped resources on failure and leaves orphaned SSA ownership that conflicts on retry. Do not use it.
- **`talosctl patch machineconfig --patch` takes a delta**, never a full config — `talos.md` § Config Management
- **Forgejo is HTTPS-only** (SSH is unreachable from OCI); the `flux-system/flux-system` secret is an apoci pull placeholder, not a Git credential — `bootstrap.md` § Flux flux-system Secret
- **PodSecurity + hostNetwork**: `network` stays `baseline`; towonel has its own namespace — `towonel.md` § Why its own namespace
- **Stale CSINode topology keys** can leave no new PVC schedulable — `storage.md` § Gotcha: stale CSINode topology keys block every new PVC
- **flate resolves `dependsOn` by `targetNamespace`**, so cross-namespace refs need `namespace:` — `flux-patterns.md` § flate `dependsOn` Namespace

---

## Where everything else is

`CLAUDE.md` imports `AGENTS.md` and the always-loaded instructions; `cluster-conventions.md` and
`yaml-conventions.md` are `paths:`-scoped rules (`ls -l .claude/rules/`) that load only when you
touch `kubernetes/**` — if a convention seems absent while editing a manifest, check the rule
loaded. `.agents/references/` is never loaded: open one when its subject comes up, and not the
whole directory.

| Read this              | When                                                                          |
| ---------------------- | ----------------------------------------------------------------------------- |
| `bootstrap.md`         | Rebuilding from nothing — the helmfile order and the network-first rule       |
| `claude-code-setup.md` | Touching a hook, a guard, a path-scoped rule, or a skill symlink              |
| `clustermesh.md`       | Cilium ClusterMesh with Artemis — routing, relay, shared CA, global services  |
| `crowdsec.md`          | A ban, a bot challenge or an exemption on any public site (both domains)      |
| `database.md`          | Onboarding onto shared Postgres, pgbouncer tuning, CNPG PKI, primary restarts |
| `flux-patterns.md`     | A reconcile is stuck, or you are wiring `dependsOn` across namespaces         |
| `networking.md`        | Gateways, the OCI VCN rules, the Cloudflare tunnel, Tailscale                 |
| `renovate.md`          | Triaging the PR queue, or a per-app update guard (tuppr, zer0ver)             |
| `status-page.md`       | `status.dcunha.io`: generated checks from both clusters, heartbeats, badges   |
| `storage.md`           | openebs-zfs, snapshot classes, the kopiur component, the restore path         |
| `talos.md`             | Node config, the schematic, extensions, upgrade steps                         |
| `towonel.md`           | towonel hub/edge — ports, grey-cloud DNS, key material, kopiur movers         |

**Skills**: `ls .agents/skills/` is the catalog; Claude Code injects each `name:` and
`description:`. A skill without frontmatter is invisible to auto-invocation, and one without a
`.claude/skills/<name>` symlink is invisible to Claude Code — `just ai lint-agents` checks both.
Cluster-agnostic skills live in `~/.claude/skills/`.

---

## Writing docs in this repo

**A doc may carry a list only when it holds a fact a `grep` or `ls` cannot recover** — an
allocation, an intent, a rationale, or a historical correction. Anything a one-line command
answers must _be_ the command, not its output. That is why the namespace table above keeps only
its purpose column.

**Never restate a rule that lives in another file.** Link to it and say which one wins; the
duplicate is what drifts.

**Make a version fact a command, not a number.** Renovate moves chart versions and tuppr moves
Talos. A doc that prints a version is stale the week after it is written.

**Manifests carry configuration, not prose.** No comments under `kubernetes/` —
`yaml-conventions.md` § No Comments in Manifests.

---

## What was deliberately removed or decided against — do not resurrect it

`grep` cannot tell you that something is absent on purpose.

- **`flux bootstrap`** — bootstrap goes through helmfile instead, because the Forgejo repo must
  already have content before Flux can sync.
- **SSH to the node** — Talos has no SSH daemon; `talosctl` over the Headscale site link is the
  only path in.
- **Open 6443/tcp and 8443/tcp** — closed on purpose; the API server is reachable over the
  Headscale site link only (`networking.md` § Oracle Cloud VCN, `bootstrap.md` for the rebuild
  window).
- **A wildcard DNS record owned by this cluster** — there is none. The grey `*.frostlink.dev`
  CNAME belongs to **Artemis**; every Frostlink app needs its own explicit record
  (`networking.md` § DNS).
- **Relaxing PodSecurity on `network`** — rejected; towonel got its own `privileged` namespace.

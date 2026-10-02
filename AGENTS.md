# Frostlink — Agent Context

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free (Ampere A1, ca-toronto-1),
reconciled by Flux CD. This file is the entry point for every AI agent working here, and it is
deliberately short: it holds what is true on **every** turn, plus an index of where everything
else lives.

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **Domain**: `frostlink.dev` | **Repo**: <https://git.dcunha.io/Exikle/frostlink>
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecrets, no SOPS
- **CNI**: Cilium | **Ingress**: two paths — Envoy Gateway (HTTPRoute, via Cloudflare tunnel) and the towonel edge (SNI on host `:443`, bypasses Envoy)
- **Inbound**: no longer zero — the towonel edge listens directly on 443/tcp + 51820/udp

`ls` at the repo root is the map. Only `kubernetes/` reconciles through Flux.

---

## The rules that apply to every turn

Everything else is conditional. These are not.

1. **`main` is production, and there is one node.** No staging cluster, and nothing to fail over
   to. Suspend the root **and** the target Kustomization, `just kube apply-ks`, then wait for the
   user to confirm the live deployment before committing. Two suspends, not one.
2. **Never apply cluster changes through an MCP tool — here that is worse than it sounds.** The
   MCP k8s tools do not point at this cluster at all; they point at **Artemis**. An MCP mutation
   run from this repo lands on the wrong cluster. Writes go through git, or `just kube apply-ks`
   during a test.
3. **Secrets are 1Password ExternalSecrets.** SOPS is not used here — never suggest age
   encryption or `sops --encrypt`.
4. **Cluster traffic uses `<app>.<namespace>.svc.cluster.local`**, never an external hostname.
5. **Stage files by name.** No `git add .`, no `git add -A`, no `--no-verify`. One-line semantic
   commit subject, no body, no `Co-Authored-By`.
6. **Never hand-edit the Talos schematic ID.** tuppr rebuilds an upgrade from the _node's_
   schematic, so a stale or hand-written ID silently reinstalls a removed extension — or drops
   `zfs` and takes all storage down. Derive it: `just talos schematic-id`, or read
   `kubectl get node frostlink -o jsonpath='{.metadata.annotations.extensions\.talos\.dev/schematic}'`.
7. **A reboot is a full outage.** Control plane and workload are the same machine
   (`allowSchedulingOnControlPlanes: true`). Treat `talosctl upgrade`/`reboot` as an outage, not a
   rolling operation — the destructive guard blocks them for that reason.
8. **Agents edit in a worktree, never the main checkout.** Before the first edit, run
   `just wt new <agent>/<slug>` (agent = `claude`, `opencode`, …) and work only in the
   `.worktrees/<agent>-<slug>` path it prints. One agent per worktree. `just wt rm <agent>/<slug>`
   when the branch is merged. A pre-commit check refuses agent commits made in the main checkout.

A rule that has to hold is enforced, not just written: `guard-destructive.sh` hard-blocks the
destructive verbs regardless of permission mode. If you find yourself reaching for a way around a
guard, that is the signal to stop and hand the change back as a commit — not to find another route.

---

## The node

One machine, so its facts are load-bearing rather than inventory.

- **VM.Standard.A1.Flex** — 4 OCPU / 24 GB RAM, ARM64 Ampere A1, 50 GB boot volume (10 VPU)
- **ca-toronto-1 AD-1**, instance `instance-20260612-2239`
- **Public** `40.233.88.33` (reserved) · **Internal** `10.0.0.203` · **Tailscale** `100.67.108.103`
- **Extensions**: `iscsi-tools`, `tailscale`, `util-linux-tools`, `zfs` — **`zfs` is load-bearing**,
  the whole `openebs-zfs` storage layer depends on it
- Live versions are a command, not a number: `talosctl version`, `kubectl version`

Management access goes over the Tailscale IP. `.mise.toml` pins `KUBECONFIG` and `TALOSCONFIG` to
the repo-local files, so **inside this repo the repo-local kubeconfig wins over `~/.kube/config`**
— no `kubectx` or `--context` step. Context `frostlink`.

Everything else about the network — VCN, DNS records, the security-list ingress set, the tunnel:
`networking.md`.

---

## Namespaces

`ls kubernetes/apps/` is the live list. The table below is kept only for the _purpose_ column,
which no command recovers.

| Namespace          | Purpose                                                                                        |
| ------------------ | ---------------------------------------------------------------------------------------------- |
| `cert-manager`     | cert-manager, ACME ClusterIssuer, CSI driver, internal Postgres CA, trust-manager              |
| `cnpg-system`      | CloudNativePG operator + barman-cloud plugin                                                   |
| `database`         | Shared CNPG Postgres `Cluster` + pgbouncer `Pooler`, shared Dragonfly                          |
| `default`          | Empty by design — nothing is deployed here                                                     |
| `dragonfly-system` | Dragonfly operator                                                                             |
| `external-secrets` | External Secrets Operator + 1Password Connect                                                  |
| `fediverse`        | GoToSocial, phanpy, apoci (OCI registry), fingerjoin                                           |
| `flux-system`      | flux-operator, flux-instance, flux-webhook, konflate                                           |
| `kopiur-system`    | Kopiur backup controller + the `r2` ClusterRepository (Cloudflare R2)                          |
| `kube-system`      | Cilium, CoreDNS, k8tz, ksgate, metrics-server, reloader                                        |
| `matrix`           | continuwuity, mautrix-signal, mautrix-whatsapp                                                 |
| `network`          | Envoy Gateway, wildcard certificates, cloudflare-tunnel, cloudflare-dns                        |
| `observability`    | VictoriaMetrics stack, alertmanager, node-exporter, kube-state-metrics, kromgo, gatus, chaski  |
| `openebs-system`   | zfs-localpv CSI — provides the default `openebs-zfs` StorageClass                              |
| `system-upgrade`   | tuppr — Talos and Kubernetes upgrade controller                                                |
| `tools`            | atuin                                                                                          |
| `towonel`          | towonel hub + edge. Its own `privileged` namespace because of `hostNetwork` — see Known Quirks |

---

## Known quirks

Each of these cost real time to find. None is recoverable by reading the tree.

- **OCI DNS**: `169.254.169.254` is the only working upstream for CoreDNS. `/etc/resolv.conf`
  resolves to `127.0.0.53`, unreachable inside pods. Set `forward . 169.254.169.254`.
- **Cilium on Talos/OCI**: `sysctlfix.enabled: false` is required — Talos has no `/etc/sysctl.d/`
  and cilium-agent's init crashes without it.
- **Helm v4 SSA conflicts**: Talos pre-installs cilium and coredns with field manager
  `helm-controller`, and helmfile uses the same one. `just bootstrap cni` installs cilium, coredns
  and cert-manager with direct `helm upgrade --install` calls to dodge the conflict.
- **`helmfile --cleanup-on-fail`** deletes cluster-scoped resources on failure, leaving orphaned
  SSA ownership that then conflicts on retry.
- **`talosctl patch machineconfig --patch` expects a DELTA**, only changed fields. Passing a full
  config duplicates array fields (e.g. `machine.files`) and breaks the node on next boot. Use a
  minimal patch file, or `talosctl apply-config --file` for a full replacement. The Tailscale
  certSANs patch is six lines for exactly this reason.
- **Forgejo auth is HTTPS, not SSH** — SSH is unreachable from OCI. Flux uses secret
  `flux-system/flux-system` with `username` + `password`.
- **PodSecurity + hostNetwork**: `network` carries no PSS label so it inherits `baseline`, which
  forbids hostNetwork and hostPorts. towonel lives in its own `privileged` namespace rather than
  relaxing `network`.
- **CSINode topology keys go stale.** tuppr labels the node
  `tuppr.home-operations.com/upgrading` during an upgrade. If the node reboots while that label is
  set, zfs-localpv bakes it into CSINode's `topologyKeys`; once tuppr removes the label the
  capacity controller can build **zero** topology segments, publish no `CSIStorageCapacity`, and
  then **no new PVC can schedule at all** — "node(s) did not have enough free storage" against a
  pool that is 90% free. Fix: `kubectl -n openebs-system rollout restart ds/zfs-localpv-node`,
  then `deploy/zfs-localpv-controller`.
- **flate resolves `dependsOn` by `targetNamespace`.** `just kube apply-ks` uses flate, so a
  cross-namespace ref needs an explicit `namespace:` (e.g. `namespace: cert-manager` for
  clusterissuer, `namespace: external-secrets` for onepassword-connect). Without it flate looks in
  the current ks's own targetNamespace and fails.

---

## Where everything else is

`.agents/instructions/` is loaded for you. `.agents/references/` is not — open one when its
trigger comes up.

### Always loaded

| File                           | What it settles                                         |
| ------------------------------ | ------------------------------------------------------- |
| `instructions/tooling.md`      | `just` recipes, kubectl/talosctl scoping, the MCP tiers |
| `instructions/commit-style.md` | The test-then-commit sequence and the signing model     |
| `instructions/session.md`      | Journal format, memini vs `.agents/` boundary           |

### Loaded when you touch a matching path

| File                                  | Loads on               |
| ------------------------------------- | ---------------------- |
| `instructions/cluster-conventions.md` | `kubernetes/**`        |
| `instructions/yaml-conventions.md`    | `kubernetes/**/*.yaml` |

Both are `paths:`-scoped rules symlinked into `.claude/rules/`. If manifest field ordering or the
app-template conventions seem absent while you are editing a manifest, that scoping is why —
confirm the rule loaded before assuming the convention changed.

### Read on demand

Open the file when its subject comes up. Do not read the whole directory.

| Read this              | When                                                                          |
| ---------------------- | ----------------------------------------------------------------------------- |
| `anubis.md`            | Adding or tuning PoW scraper deterrence, or GoToSocial's allow policy         |
| `bootstrap.md`         | Rebuilding from nothing — the helmfile order and the network-first rule       |
| `claude-code-setup.md` | Touching a hook, a guard, a path-scoped rule, or a skill symlink              |
| `database.md`          | Onboarding onto shared Postgres, pgbouncer tuning, CNPG PKI, primary restarts |
| `flux-patterns.md`     | A reconcile is stuck, or you are wiring `dependsOn` across namespaces         |
| `networking.md`        | Gateways, the OCI VCN rules, the Cloudflare tunnel, Tailscale                 |
| `renovate.md`          | Triaging the PR queue, or a per-app update guard (tuppr, zer0ver)             |
| `storage.md`           | openebs-zfs, snapshot classes, the kopiur component, the restore path         |
| `talos.md`             | Node config, the schematic, extensions, upgrade steps                         |
| `towonel.md`           | towonel hub/edge — ports, grey-cloud DNS, key material, kopiur movers         |

### Skills

`ls .agents/skills/` is the catalog. Claude Code injects each skill's `name:` and `description:`
itself, so a table here would be a second copy that drifts — which is exactly what happened twice
in the sibling Artemis repo before the table was deleted there.

A skill without frontmatter is invisible to auto-invocation; a skill without a
`.claude/skills/<name>` symlink is invisible to Claude Code. `just ai lint-agents` checks both.

Cluster-agnostic skills live in `~/.claude/skills/` and work everywhere: `forgejo`,
`triage-renovate`, `build-container`, `playwright`, `add-agent-content`.

---

## Writing docs in this repo

**A doc may carry a list only when it holds a fact a `grep` or `ls` cannot recover** — an
allocation, an intent, a rationale, or a historical correction. Anything a one-line command
answers must _be_ the command, not its output. That is why the namespace table above keeps only
its purpose column, and why no app or version list appears anywhere in this file.

**Never restate a rule that lives in another file.** Link to it and say which one wins; the
duplicate is what drifts.

**Make a version fact a command, not a number.** Renovate moves chart versions and tuppr moves
Talos. A doc that prints a version is stale the week after it is written.

**Manifests carry configuration, not prose.** No comments under `kubernetes/`; rationale goes in a
reference doc. The machine-oriented exceptions are in `yaml-conventions.md`.

---

## What was deliberately removed or decided against — do not resurrect it

`grep` cannot tell you that something is absent on purpose.

- **SOPS** — not used here. 1Password ExternalSecrets only.
- **`flux bootstrap`** — bootstrap goes through helmfile instead, because the Forgejo repo must
  already have content before a Flux GitRepository can sync.
- **SSH to the node** — Talos has no SSH, and 22/tcp is closed. `talosctl` over Tailscale is the
  only path in.
- **Open 6443/tcp** — removed from the security list 2026-08-18. The API server is reachable over
  Tailscale only. 8443/tcp and 80/tcp are deliberately closed too.
- **A wildcard DNS record owned by this cluster** — there is none. The grey `*.frostlink.dev`
  CNAME to `edge.frostlink.dev` exists but is owned by **Artemis** (towonel); every Frostlink app
  still needs its own explicit record — see `networking.md`. `edge.frostlink.dev` is a DNS-only A
  record; `frostlink.dev` and `external.frostlink.dev` are proxied CNAMEs to the tunnel.
- **Relaxing PodSecurity on `network`** — rejected. towonel got its own `privileged` namespace
  instead, so the gateway namespace keeps `baseline`.

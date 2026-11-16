# home-infra — Agent Context

The home infrastructure repo. Each cluster has its own folder under `kube/clusters/`. Today there
are two, both Talos Linux clusters reconciled by Flux CD:

- **Artemis**: the homelab cluster, many nodes, at home.
- **Frostlink**: one node on Oracle Cloud. It is the public front door and the always-on host
  (`.agents/references/oci-node.md`).

This file is the entry point for every AI agent that works here. It is short on purpose. It
holds what is true on every turn, and an index of where everything else is.

- Global rules (identity, commit hygiene, delegation, memory, Bash calls) load from
  `~/.agents/AGENTS.md` and `~/.agents/rules/` every session. This file does not restate them.
- Domains: `dcunha.io` (Artemis), `frostlink.dev` (Frostlink) | Repo: <https://git.dcunha.io/exikle/home-infra>
- GitOps: Flux CD + Flux Operator | Secrets: 1Password ExternalSecret, no SOPS
- CNI: Cilium | Ingress: Envoy Gateway (Gateway API / HTTPRoute)

`ls` at the repo root is the map. `kube/` holds everything Flux deploys.
`kube/clusters/<cluster>/` holds one cluster: its `apps/`, `components/`, `talos/`, `bootstrap/`
and `mise.toml`. `kube/base/<ns>/<app>/` holds one copy of an app that both clusters run. Each
cluster turns it on with one line in its namespace menu, `kube/clusters/<cluster>/apps/<ns>/kustomization.yaml`.
A change under `kube/base/` reaches both clusters in one push. The layout, its rules and the
remaining steps are in #3333. `app-structure.md` § Shared apps has the file shape.

One CI workflow (`.forgejo/workflows/oci-push.yaml`) builds one Flux artifact per cluster from
the repo root. Each artifact keeps only `kube/base/` and the Flux folders of
its own cluster. So every `spec.path` is relative to the repo root and starts with
`./kube/clusters/<cluster>/` or `./kube/base/`. Flux cannot see `terraform/`, `ansible/`, the
other cluster, or `talos/` and `bootstrap/`.

**A command names its cluster in its path.** `mise run //kube/clusters/artemis:apply-ks`
and `mise run //kube/clusters/frostlink:apply-ks` are different tasks. Each cluster folder
sets its own `KUBECONFIG`, `TALOSCONFIG` and `KUBE_CONTEXT`. The repo root sets none. Never run a
cluster task by its short name, and never use a bare `kubectl`. Frostlink is `kubectl --context frostlink`.

---

## The rules that apply to every turn

Everything else is conditional. These rules are not.

1. `main` is production. There is no staging cluster. Every push reconciles immediately.
   Suspend the root Kustomization and the target Kustomization of that cluster. Run its `apply-ks`
   (`mise run //kube/clusters/<cluster>:apply-ks`). Then
   wait for the user to confirm the live deployment before you commit. Suspend twice, not once.
   `apply-ks` suspends nothing, and a child that reconciles on its own interval silently reverts
   your edits.
2. Never apply cluster changes through an MCP tool. The MCP k8s tools are for read-only
   inspection, and **they point at Artemis only**. For Frostlink use `kubectl --context frostlink`,
   never an MCP tool. Writes go through git, or through the `apply-ks` task of the cluster during a test.
3. Secrets are 1Password ExternalSecrets (`ClusterSecretStore: onepassword-connect`). SOPS is
   fully removed. Never suggest age encryption or `sops --encrypt`.
4. Pods are dual-stack, but in practice they talk IPv4. Pods get a ULA IPv6 address beside
   IPv4. Services stay IPv4-only unless they opt in. CoreDNS answers every AAAA with NODATA,
   so pods only ever dial IPv4 by name. An `ENETUNREACH` on IPv6 means the address came from
   somewhere other than cluster DNS. `networking.md` § Dual-stack wins over this line.
5. Cluster traffic uses `<app>.<namespace>.svc.cluster.local`, never an external hostname.
6. Parked or blocked work becomes a Forgejo issue, never only a journal bullet.
7. Agents edit in a worktree, never the main checkout. Before the first edit, run
   `mise run //:wt:new <type>/<slug>` (`feat`, `fix`, `chore`, … as in commit subjects). Work only in
   the `.worktrees/<type>-<slug>` path that it prints. One agent per worktree. Run
   `mise run //:wt:rm <type>/<slug>` when the branch is merged. A pre-commit check refuses agent commits
   made in the main checkout.
8. Frostlink is one node, so a reboot is a full outage. Never `talosctl upgrade`, `reboot` or
   `shutdown` it by hand: use `mise run //kube/clusters/frostlink/talos:upgrade <version>`, with the user
   watching. Never type or hand-edit its Talos schematic ID. Derive it with
   `mise run //kube/clusters/frostlink/talos:schematic-id` (`oci-talos.md` § Schematic).

The system enforces a rule that has to hold. It is not only written down. `guard-destructive.sh`
hard-blocks the destructive verbs, whatever the permission mode. If you
reach for a way around a guard, stop. Hand the change back as a commit. Do not look for another
route.

---

## Where everything else is

The client loads `.agents/instructions/` for you. It does not load `.agents/references/`. Open
one when its trigger comes up.

### Always loaded

| File                           | What it settles                                     |
| ------------------------------ | --------------------------------------------------- |
| `instructions/tooling.md`      | mise tasks, the MCP tiers, briefing subagents       |
| `instructions/commit-style.md` | The test-then-commit sequence and the signing model |
| `instructions/session.md`      | Journal hooks, memini vs `.agents/` boundary        |

### Loaded when you touch a matching path

| File                                  | Loads on                                                                     |
| ------------------------------------- | ---------------------------------------------------------------------------- |
| `instructions/cluster-conventions.md` | `kube/base/**`, `kube/components/**`, `kube/clusters/*/{apps,components}/**` |
| `instructions/yaml-conventions.md`    | the same folders, `*.yaml` only                                              |
| `instructions/frostlink.md`           | `kube/clusters/frostlink/{apps,components}/**`                               |

All three are `paths:`-scoped rules symlinked into `.claude/rules/`. `frostlink.md` holds only
what differs from the shared two, and wins there. If the manifest field ordering or
the app-template conventions seem absent while you edit a manifest, that scoping is the reason.
Make sure that the rule loaded before you assume the convention changed. opencode has no path
scoping and globs every instruction file unconditionally.

### Read on demand

Open the file when its subject comes up. Do not read the whole directory.

| Read this                    | When                                                                                |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| `ansible.md`                 | Changing host config outside Kubernetes: TrueNAS, pantheon, Forgejo                 |
| `app-structure.md`           | Choosing a directory shape for a new app, or wondering why one looks odd            |
| `bootstrap.md`               | Rebuilding the cluster from nothing, or editing a `.j2` template                    |
| `ci.md`                      | A Forgejo workflow, the runner, buildkit, or the `oci-push` Flux artifact           |
| `claude-code-remote.md`      | The in-cluster Claude Code Remote Control pod: access, bootstrap, tools             |
| `claude-code-setup.md`       | Touching a hook, a guard, or a skill/subagent symlink                               |
| `cortex-mcp.md`              | An MCP server misbehaves, or you are adding one                                     |
| `crowdsec.md`                | A ban, a bot challenge or an exemption on any public site (Frostlink, both domains) |
| `database.md`                | Frostlink: shared Postgres onboarding, pgbouncer tuning, CNPG PKI, primary restarts |
| `flux-patterns.md`           | A reconcile is stuck, or you are wiring `dependsOn` across namespaces               |
| `gpu.md`                     | Scheduling anything onto the Arc A380 or ymir's iGPU                                |
| `hardware.md`                | Sizing a workload, pinning to a node, buying a part, or an unexplained stall        |
| `hermes.md`                  | Changing hermes-agent's model, skills, or chaski wiring                             |
| `identity-stack.md`          | Wiring SSO: lldap, Pocket-ID, tinyauth                                              |
| `issue-tracking.md`          | Filing the Forgejo issue that parked work becomes                                   |
| `kopiur.md`                  | Backups and restores                                                                |
| `media-stack.md`             | The arr stack, cross-seed, download clients, zeroscaler                             |
| `memory-config.md`           | Editing `.mcp.json` tiers or memini plugin usage                                    |
| `networking.md`              | Gateways, VLANs, CoreDNS, BGP, Multus: read before any RA or DNS change             |
| `observability.md`           | VictoriaMetrics, Grafana, ServiceMonitors, kromgo                                   |
| `oci-networking.md`          | Frostlink: the OCI VCN, the front door, DNS records, Tailscale access               |
| `oci-node.md`                | Frostlink: the node, its namespaces and its known quirks                            |
| `oci-rebuild.md`             | Rebuilding Frostlink from nothing: helmfile order and the network-first rule        |
| `oci-talos.md`               | Frostlink: node config, the schematic, extensions, the single-node upgrade          |
| `openebs-zfs.md`             | Frostlink: openebs-zfs, snapshot classes, the kopiur restore path                   |
| `pantheon-networking.md`     | pantheon's vNIC/bridge: single-NIC blast radius, tap pps knee                       |
| `pantheon-zfs.md`            | pantheon's ZFS pools, HBA bays, drive intake                                        |
| `pod-security-exceptions.md` | An app needs to deviate from the default security context                           |
| `postgres-dragonfly.md`      | Onboarding an app onto shared Postgres or Dragonfly                                 |
| `renovate.md`                | Triaging the PR queue, or a per-app update guard                                    |
| `scheduling.md`              | Packing, descheduler thresholds, cordoning a node                                   |
| `status-page.md`             | `status.dcunha.io`: generated checks from both clusters, heartbeats, badges         |
| `storage.md`                 | StorageClasses, the NFS media mount, orphaned PVCs                                  |
| `talos.md`                   | Node config, schematics, extensions, upgrades                                       |
| `terraform.md`               | OpenTofu: the ownership boundary and import-first rule                              |
| `towonel-agent.md`           | Publishing any public service (either domain) on `edge-gateway` via towonel         |
| `towonel.md`                 | Frostlink: the towonel hub and edge, ports, grey-cloud DNS, key material            |

### Skills and subagents

`ls .agents/skills/` and `ls .agents/agents/` are the catalogs. Both clients inject the `name:`
and `description:` of each one themselves. A table here would be a third copy that drifts. It
drifted twice before this note replaced it.

Auto-invocation cannot see a skill without frontmatter. Claude Code cannot see a skill without a
`.claude/skills/<name>` symlink. It also cannot see a subagent without a
`.claude/agents/<name>.md` symlink. `mise run //ai:lint-agents` checks all of this.

Cluster-agnostic skills live in `~/.claude/skills/` and work everywhere: `forgejo`,
`triage-renovate`, `build-container`, `playwright`, `add-agent-content`, `simple-english`.

---

## Writing docs in this repo

### Plain English

Load the `simple-english` skill before you write a new markdown file or change an existing one.
This covers `README.md` files, `AGENTS.md`, everything in `.agents/`, and the markdown that the
Hermes and Claude Code pods mount. Write the new text in the style of the skill. Do not rewrite
the parts of a file that you did not need to change.

The skill never changes code, commands, identifiers, paths, quoted errors or facts. A skill
description in frontmatter stays on one line. It can use an em-dash, because `mise run //ai:lint-agents`
rejects a colon followed by a space in that value.

### The list rule

A doc may carry a list only when the list holds a fact that a `grep` or `ls` cannot recover. Such
a fact is an allocation, an intent, a rationale, or a historical correction. If a one-line
command answers the question, the doc must give the command, not its output.

Keep these, because the fact is not in the tree:

- The Dragonfly index registry. An index that is _claimed but unconfigured_ exists nowhere else.
- The media port tables. They record which ports were deliberately normalised and which were not.
- The app _role_ columns ("Prowlarr is the indexer source of truth").
- The hardware inventory (which SSD is in which box).

Delete these, because the tree already answers the question:

- Which apps carry a component (`grep -rln 'components/<name>' kube/clusters/artemis/apps/`).
- How many apps carry it.
- Which apps are on shared Postgres or in a namespace.
- Dated snapshot columns, such as key counts and live versions.

An outstanding action item is not a list at all. Parked work becomes a Forgejo issue, and the doc
links to it. A strikethrough TODO in a reference doc is the failure that this rule exists to stop.

### Never restate a rule that lives in another file

Link to it and say which one wins. The duplicate is what drifts. This risk is real. A sibling
repo logged a wrong `Approve` on a PostgreSQL major-version upgrade because a copied rule had
drifted from its original.

### Make a version fact a command, not a number

Renovate bumps `app-template` across the whole fleet. A doc that prints a tag is stale the week
after the doc is written. Print the command that recovers the tag instead:
`grep -h 'tag:' kube/clusters/artemis/apps/*/*/app/ocirepository.yaml | sort | uniq -c | sort -rn | head -1`.

### Manifests carry configuration, not prose

No comments under `kube/base/` or `kube/clusters/*/`. Rationale goes in a reference doc. There it is searchable, and
no one must re-read it on every manifest edit. The three machine-oriented exceptions are in
`yaml-conventions.md`.

---

## What was deliberately removed — do not resurrect it

`grep` cannot tell you that something is absent on purpose.

- Rook-Ceph: removed in `b9008ac55`. There is no `ceph-block`, no CephFS, and no CephCluster CRD.
  The only StorageClasses are `miroir` (the cluster default, 2 replicas, use this one) and
  `miroir-local` (1 replica, for kopiur caches and staging clones only). Both are RWO. Neither
  offers RWX. If you pick `miroir-local` for the data of an app, the data is unreplicated.
- SOPS: fully removed. Never suggest age encryption.
- Dedicated per-app Postgres: immich was the last one. It moved into the shared cluster on
  2026-09-01. The silo-first policy was superseded on 2026-07-02.
- VolSync: replaced by kopiur. The `ReplicationSource` and `ReplicationDestination` CRDs no longer
  exist.
- Retired skills (2026-08-21): `cnpg-database` (merged into `deploy-app` +
  `postgres-dragonfly.md`), `migrate-namespace` (built on CRDs that are gone), and
  `kopiur-pvc-migrate` (a completed one-shot migration).
- Frostlink, decided against or removed. `grep` cannot tell you these are on purpose:
    - `flux bootstrap`. The rebuild goes through helmfile, because the Forgejo repo must hold content before Flux can sync.
    - SSH to the node. Talos has no SSH daemon. `talosctl` over the Headscale site link is the only way in.
    - Open 6443/tcp and 8443/tcp. They are closed on purpose (`oci-networking.md` § Oracle Cloud VCN).
    - A wildcard DNS record owned by Frostlink. Every Frostlink app has its own explicit record.
    - The Cloudflare Tunnel (retired 2026-11-12). Every public record is grey and points at the node.
    - PROXY-protocol passthrough to Artemis. Envoy terminates TLS and reaches Artemis over the towonel backhaul.
    - Cilium ClusterMesh between the clusters (removed 2026-11-14). The Cilium cluster ID and name stay as leftovers.
    - Relaxing PodSecurity on `network`. towonel has its own `privileged` namespace.
- The audit half of `review-app` (2026-09-01): the skill did a one-minute lint and a deep audit
  under one name. The lint always finished first and reported PASS, so the audit never ran.
  `review-app` is now the lint only. The audit moved to the `audit-app` subagent.

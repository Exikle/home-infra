# home-infra — Agent Context

This is the home infrastructure repo. Each cluster has its own folder under `kube/clusters/`.
Today there are two. Both are Talos Linux clusters, and Flux CD reconciles both (it makes the
live cluster match the repo):

- Artemis: the homelab cluster, many nodes, at home.
- Frostlink: one node on Oracle Cloud. It is the public front door and the always-on host
  (`.agents/references/oci-node.md`).

This file is the entry point for every AI agent that works here. It is short on purpose. It
holds what is true on every turn, and an index of where everything else is.

- Global rules (identity, commit hygiene, delegation, memory, Bash calls) load from
  `~/.agents/AGENTS.md` and `~/.agents/rules/` every session. This file does not restate them.
- Domains: `dcunha.io` (Artemis), `frostlink.dev` (Frostlink) | Repo: <https://git.dcunha.io/exikle/home-infra>
- GitOps: Flux CD + Flux Operator | Secrets: 1Password ExternalSecret, no SOPS
- CNI: Cilium | Ingress: Envoy Gateway (Gateway API / HTTPRoute)

The three files below load on every turn. Claude Code follows these `@` imports. opencode loads
the same files through `opencode.json`. There is no `CLAUDE.md` in this repo, on purpose. Claude
Code reads `AGENTS.md` only when no `CLAUDE.md` exists.

@.agents/instructions/tooling.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md

`ls` at the repo root is the map. `kube/` holds everything that Flux deploys.
An app that both clusters run is a shared app. It lives once, complete, in `kube/base/<ns>/<app>/`,
with its `ks.yaml`. The menu `kube/base/<ns>/kustomization.yaml` lists that `ks.yaml`. If a
cluster runs a shared app differently, only the differences go in
`kube/clusters/<cluster>/overlays/<ns>/<app>/`. A shared app with no differences has no folder in
any cluster.

`kube/clusters/<cluster>/` holds one cluster: its `apps/`, `overlays/`, `components/`, `talos/`,
`bootstrap/` and `mise.toml`. An app that only one cluster runs lives in
`kube/clusters/<cluster>/apps/<ns>/<app>/ks.yaml`, and its namespace menu
(`kube/clusters/<cluster>/apps/<ns>/kustomization.yaml`) lists that file. The one file
`kube/clusters/<cluster>/apps/base/kustomization.yaml` links the cluster to `kube/base/`. It also
holds the patches for the few Kustomization fields that differ per cluster.
`kube/components/` holds kustomize components that both clusters use the same way.

Components that one cluster uses, or that each cluster builds differently, stay in
`kube/clusters/<cluster>/components/`. A change under `kube/base/` or `kube/components/` reaches
both clusters in one push. `app-structure.md` § Shared apps has the file shape, and it wins.

One CI workflow (`.forgejo/workflows/oci-push.yaml`) builds one Flux artifact per cluster from
the repo root. Each artifact keeps only `kube/base/`, `kube/components/` and the Flux folders of
its own cluster. For this reason, every `spec.path` is relative to the repo root. It starts with
`./kube/clusters/<cluster>/` or, for a shared app, `./kube/clusters/current/`. Flux cannot see
`terraform/`, `ansible/`, the other cluster, or `talos/` and `bootstrap/`. In the cluster, two
`ArtifactGenerator`s cut that artifact into one artifact per app, so a push reconciles only the
apps that it changed (`app-structure.md` § Per-app artifacts).

A command names its cluster in its path. `mise run //kube/clusters/artemis:apply-ks` and
`mise run //kube/clusters/frostlink:apply-ks` are different tasks. Each cluster folder sets its
own `KUBECONFIG`, `TALOSCONFIG` and `KUBE_CONTEXT`. The repo root sets none. Never run a cluster
task by its short name. Never use a bare `kubectl`. For Frostlink, use
`kubectl --context frostlink`.

---

## The rules that apply to every turn

Everything else is conditional. These rules are not.

1. `main` is production. There is no staging cluster. Every push to `main` reaches the cluster
   as soon as CI publishes its artifact.
   Before you commit, suspend the root Kustomization and the target Kustomization of that
   cluster. Suspend twice, not once. Then run the `apply-ks` of that cluster
   (`mise run //kube/clusters/<cluster>:apply-ks`). Then wait until the user tells you that
   the live deployment works. Only then commit. `apply-ks` suspends nothing. A child that
   reconciles on its own interval silently reverts your edits.
2. Never apply cluster changes through an MCP tool. The MCP k8s tools are for read-only
   inspection. They point at Artemis only. For Frostlink, use `kubectl --context frostlink`,
   never an MCP tool. Writes go through git. During a test, writes can also go through the
   `apply-ks` task of the cluster.
3. Secrets are 1Password ExternalSecrets (`ClusterSecretStore: onepassword-connect`). SOPS is
   fully removed. Never suggest age encryption or `sops --encrypt`.
4. (Artemis) Pods are dual-stack, but in practice they talk IPv4. Pods get a ULA IPv6 address
   beside IPv4. Services stay IPv4-only unless they opt in. CoreDNS answers every AAAA query with
   NODATA. So pods only ever dial IPv4 by name. An `ENETUNREACH` on IPv6 means that the address
   came from somewhere other than cluster DNS. `networking.md` § Dual-stack wins over this line.
   Frostlink pods are IPv4-only.
5. Cluster traffic uses the in-cluster name, never an external hostname. Both
   `<app>.<namespace>.svc.cluster.local` and the short form `<app>.<namespace>.svc` are fine.
6. Parked or blocked work becomes a Forgejo issue, never only a journal bullet.
7. Agents edit in a worktree, never in the main checkout. Before the first edit, run
   `mise run //:wt:new <type>/<slug>`. The `<type>` is a commit-subject type (`feat`, `fix`,
   `chore`, …). Work only in the `.worktrees/<type>-<slug>` path that the task prints. Use one
   agent per worktree. When the branch is merged, run `mise run //:wt:rm <type>/<slug>`. A
   pre-commit check refuses agent commits made in the main checkout.
8. Frostlink is one node, so a reboot is a full outage. Never `talosctl upgrade`, `reboot` or
   `shutdown` it by hand. Use `mise run //kube/clusters/frostlink/talos:upgrade <version>`, with
   the user watching. Never type or hand-edit its Talos schematic ID. Derive it with
   `mise run //kube/clusters/frostlink/talos:schematic-id` (`oci-talos.md` § Schematic).

The system enforces each rule that has to hold. The rule is not only written down.
`guard-destructive.sh` hard-blocks the destructive verbs in every permission mode. If you reach
for a way around a guard, stop. Hand the change back as a commit. Do not look for another route.

---

## Where everything else is

The client loads `.agents/instructions/` for you. It does not load `.agents/references/`. When
the trigger of a reference comes up, open that reference.

### Always loaded

| File                           | What it settles                                     |
| ------------------------------ | --------------------------------------------------- |
| `instructions/tooling.md`      | mise tasks, the MCP tiers, briefing subagents       |
| `instructions/commit-style.md` | The test-then-commit sequence and the signing model |
| `instructions/session.md`      | Journal hooks, memini vs `.agents/` boundary        |

### Loaded when you touch a matching path

| File                                  | Loads on                                                                              |
| ------------------------------------- | ------------------------------------------------------------------------------------- |
| `instructions/cluster-conventions.md` | `kube/base/**`, `kube/components/**`, `kube/clusters/*/{apps,overlays,components}/**` |
| `instructions/yaml-conventions.md`    | the same folders, `*.yaml` only                                                       |
| `instructions/frostlink.md`           | `kube/clusters/frostlink/{apps,overlays,components}/**`                               |

All three are `paths:`-scoped rules, symlinked into `.claude/rules/`. Such a rule loads only when
you touch a file that matches its paths. `frostlink.md` holds only what differs from the shared
two. Where they differ, `frostlink.md` wins. If the manifest field ordering or the app-template
conventions seem absent while you edit a manifest, that scoping is the reason. Make sure that the
rule loaded before you assume that the convention changed. opencode has no path scoping. It
globs every instruction file unconditionally.

### Read on demand

When the subject of a file comes up, open that file. Do not read the whole directory.

| Read this                    | When                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------------ |
| `ansible.md`                 | You change host configuration outside Kubernetes: TrueNAS, pantheon, Forgejo                           |
| `app-structure.md`           | You choose a directory shape for a new app, or wonder why one looks odd                                |
| `bootstrap.md`               | Artemis: you rebuild the cluster from nothing, or edit a `.j2` template                                |
| `ci.md`                      | A Forgejo workflow, the runner, buildkit, or the `oci-push` Flux artifact                              |
| `claude-code-remote.md`      | The in-cluster Claude Code Remote Control pod: access, bootstrap, tools                                |
| `claude-code-setup.md`       | You touch a hook, a guard, or a skill/subagent symlink                                                 |
| `cliproxyapi.md`             | kritika's Claude reviews fail, the Claude login expired, or a new app needs Claude through cliproxyapi |
| `cortex-mcp.md`              | An MCP server misbehaves, or you add one                                                               |
| `crowdsec.md`                | A ban, a bot challenge or an exemption on any public site (Frostlink, both domains)                    |
| `database.md`                | Frostlink: shared Postgres onboarding, pgbouncer tuning, CNPG PKI, primary restarts                    |
| `flux-patterns.md`           | A reconcile is stuck, or you wire `dependsOn` across namespaces                                        |
| `gpu.md`                     | Artemis: you schedule anything onto the Arc A380 or ymir's iGPU                                        |
| `hardware.md`                | Artemis: you size a workload, pin to a node, buy a part, or see an unexplained stall                   |
| `hermes.md`                  | You change hermes-agent's model, skills, or chaski wiring                                              |
| `identity-stack.md`          | You wire SSO: lldap, Pocket-ID, tinyauth                                                               |
| `issue-tracking.md`          | You file the Forgejo issue that parked work becomes                                                    |
| `kopiur.md`                  | Backups and restores                                                                                   |
| `media-stack.md`             | The arr stack, cross-seed, download clients, zeroscaler                                                |
| `memini-tuning.md`           | You tune memini recall, rerank or the write path, or its LLM budget                                    |
| `memory-config.md`           | You edit `.mcp.json` tiers or memini plugin usage                                                      |
| `networking.md`              | Gateways, VLANs, CoreDNS, BGP, Multus. Read it before any RA or DNS change                             |
| `observability.md`           | VictoriaMetrics, Grafana, ServiceMonitors, kromgo                                                      |
| `oci-networking.md`          | Frostlink: the OCI VCN, the front door, DNS records, Tailscale access                                  |
| `oci-node.md`                | Frostlink: the node, its namespaces and its known quirks                                               |
| `oci-rebuild.md`             | You rebuild Frostlink from nothing: helmfile order and the network-first rule                          |
| `oci-talos.md`               | Frostlink: node configuration, the schematic, extensions, the single-node upgrade                      |
| `openebs-zfs.md`             | Frostlink: openebs-zfs, snapshot classes, the kopiur restore path                                      |
| `pantheon-networking.md`     | pantheon's vNIC/bridge: single-NIC blast radius, tap pps knee                                          |
| `pantheon-zfs.md`            | pantheon's ZFS pools, HBA bays, drive intake                                                           |
| `pod-security-exceptions.md` | An app must deviate from the default security context                                                  |
| `postgres-dragonfly.md`      | Artemis: you onboard an app onto shared Postgres or Dragonfly                                          |
| `renovate.md`                | You triage the PR queue, or a per-app update guard                                                     |
| `scheduling.md`              | Artemis: packing, descheduler thresholds, cordoning a node                                             |
| `status-page.md`             | `status.dcunha.io`: generated checks from both clusters, heartbeats, badges                            |
| `storage.md`                 | Artemis: StorageClasses, the NFS media mount, orphaned PVCs                                            |
| `talos.md`                   | Artemis: node configuration, schematics, extensions, upgrades                                          |
| `terraform.md`               | OpenTofu: the ownership boundary and the import-first rule                                             |
| `towonel-agent.md`           | You publish any public service (either domain) on `edge-gateway` via towonel                           |
| `towonel.md`                 | Frostlink: the towonel hub and edge, ports, grey-cloud DNS, key material                               |

### Skills and subagents

`ls .agents/skills/` and `ls .agents/agents/` are the catalogues. Both clients inject the `name:`
and `description:` of each one themselves. A table here is a third copy, and that copy drifts.

Auto-invocation cannot see a skill without frontmatter. Claude Code cannot see a skill without a
`.claude/skills/<name>` symlink. It also cannot see a subagent without a
`.claude/agents/<name>.md` symlink. `mise run //ai:lint-agents` checks all of this.

Cluster-agnostic skills live in `~/.claude/skills/` and work everywhere. Run
`ls ~/.claude/skills` for the list.

---

## Writing docs in this repo

### Plain English

Before you write a new markdown file or change an existing one, load the `simple-english` skill.
This covers `README.md` files, `AGENTS.md`, everything in `.agents/`, and the markdown that the
Hermes and Claude Code pods mount. Write the new text in the style of the skill. Do not rewrite
the parts of a file that you did not need to change.

The skill never changes code, commands, identifiers, paths, quoted errors or facts. A skill
description in frontmatter stays on one line. It can use an em-dash, because
`mise run //ai:lint-agents` rejects a colon followed by a space in that value.

### The list rule

A doc can carry a list only when the list holds a fact that a `grep` or `ls` cannot recover. Such
a fact is an allocation, an intent, a rationale, or a historical correction. If a one-line
command answers the question, the doc must give the command, not its output.

Keep these, because the fact is not in the tree:

- The Dragonfly index registry. An index that is _claimed but unconfigured_ exists nowhere else.
- The media port tables. They record which ports were deliberately normalized and which were not.
- The app _role_ columns ("Prowlarr is the indexer source of truth").
- The hardware inventory (which SSD is in which box).

Delete these, because the tree already answers the question:

- Which apps carry a component (`grep -rln 'components/<name>' kube/clusters/artemis/apps/`).
- How many apps carry it.
- Which apps are on shared Postgres or in a namespace.
- Dated snapshot columns, such as key counts and live versions.

An outstanding action item is not a list at all. Parked work becomes a Forgejo issue, and the doc
links to it. This rule exists to stop one failure: a strikethrough TODO in a reference doc.

### Never restate a rule that lives in another file

Link to the rule, and say which file wins. The duplicate is what drifts.

### Make a version fact a command, not a number

Renovate bumps `app-template` across the whole fleet. A doc that prints a tag goes stale the week
after you write it. Print the command that recovers the tag instead:
`grep -rl app-template --include=ocirepository.yaml kube | xargs grep -h 'tag:' | sort | uniq -c | sort -rn | head -1`.

### Manifests carry configuration, not prose

Do not put comments in manifests. Put the rationale in a reference doc. There it is searchable,
and no one must re-read it on every manifest edit. `yaml-conventions.md` § No Comments in
Manifests has the scope and the three machine-oriented exceptions, and it wins.

---

## What was deliberately removed — do not resurrect it

`grep` cannot tell you that something is absent on purpose.

- (Artemis) Rook-Ceph: removed in `b9008ac55`. There is no `ceph-block`, no CephFS, and no
  CephCluster CRD. The only StorageClasses are `miroir` and `miroir-local`. `miroir` is the
  cluster default, with 2 replicas. Use this one. `miroir-local` has 1 replica, and it is for
  kopiur caches and staging clones only. Both are RWO. Neither offers RWX. If you pick
  `miroir-local` for the data of an app, the data is unreplicated. Frostlink has one
  StorageClass, `openebs-zfs`, and it is the default.
- Dedicated per-app Postgres: immich was the last one. It moved into the shared cluster on
  2026-09-01. The silo-first policy was superseded on 2026-07-02.
- VolSync: replaced by kopiur. The `ReplicationSource` and `ReplicationDestination` CRDs no longer
  exist.
- Frostlink items that were decided against or removed. `grep` cannot tell you that these are on
  purpose:
    - `flux bootstrap`. The rebuild goes through helmfile, because the Forgejo repo must hold
      content before Flux can sync.
    - SSH to the node. Talos has no SSH daemon. `talosctl` over the Headscale site link is the
      only way in.
    - Open 6443/tcp and 8443/tcp. They are closed on purpose
      (`oci-networking.md` § Oracle Cloud VCN).
    - A wildcard DNS record owned by Frostlink. Every Frostlink app has its own explicit record.
    - The Cloudflare Tunnel (retired 2026-11-12). Every public record is grey and points at the
      node.
    - PROXY-protocol passthrough to Artemis. Envoy terminates TLS and reaches Artemis over the
      towonel backhaul.
    - Cilium ClusterMesh between the clusters (removed 2026-11-14). The Cilium cluster ID and name
      stay as leftovers.
    - Relaxing PodSecurity on `network`. towonel has its own `privileged` namespace.
- A `ks.yaml` per cluster for a shared app, `extras/` folders and `<app>-extras` Kustomizations
  (removed 2026-11-22). A shared app has one `ks.yaml`, in `kube/base/`, and the differences of
  a cluster sit in its `overlays/` folder (`app-structure.md` § Shared apps). A cluster menu
  never lists `kube/base/`. Only `apps/base/kustomization.yaml` links a cluster to it.
  `scripts/check-kube-menus.py` fails on a shared app that also has a folder in a cluster's
  `apps/`, and on a cluster menu that lists `kube/base/`.
- The audit half of `review-app` (2026-09-01): the skill did a one-minute lint and a deep audit
  under one name. The lint always finished first and reported PASS, so the audit never ran.
  `review-app` is now the lint only. The audit moved to the `audit-app` subagent.

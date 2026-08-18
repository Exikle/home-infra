# Frostlink — Claude Context

> **Full hardware/networking reference**: `AGENTS.md`
> **Behavioral rules and runbooks**: `.agents/`

## What Is This

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free ARM64 (ca-toronto-1). Most external traffic arrives via the Cloudflare tunnel, but **this is no longer a zero-inbound-port cluster** — the towonel edge listens directly on 443/tcp and 51820/udp so other machines can publish through it. Management via Tailscale. Every push to `main` reconciles immediately to production via Flux. **No staging cluster — test with `just kube apply-ks` before committing.**

## Cluster Map

| Namespace          | Key Apps                                                      | Status       |
| ------------------ | ------------------------------------------------------------- | ------------ |
| `kube-system`      | Cilium 1.17.4, CoreDNS 1.14.6                                 | ✓ running    |
| `cert-manager`     | cert-manager 1.20.2                                           | ✓ running    |
| `external-secrets` | External Secrets 2.6.0, 1Password Connect 2.4.1               | ✓ running    |
| `flux-system`      | flux-operator 0.52.0, Flux v2.8.8                             | ✓ running    |
| `network`          | Envoy Gateway, wildcard cert, cloudflare-tunnel               | ✓ running    |
| `fediverse`        | GoToSocial (social.frostlink.dev), phanpy, apoci (registry)   | ✓ running    |
| `matrix`           | continuwuity, mautrix-signal, mautrix-whatsapp                | ✓ running    |
| `database`         | shared CNPG Postgres + pooler, shared Dragonfly               | ✓ running    |
| `observability`    | VictoriaMetrics, vmagent, alertmanager, kromgo, gatus, chaski | ✓ running    |
| `towonel`          | towonel hub + edge — tunnel for other machines (hostNetwork)   | ✓ running    |

## Node

**Single node `frostlink`** — ARM64 Ampere A1, 4 OCPU / 24 GB RAM  
Tailscale: `100.67.108.103` | Public IP: `40.233.88.33` | kubeconfig context: `frostlink`  
Talos v1.14.0-rc.1 | Kubernetes v1.36.1 | `allowSchedulingOnControlPlanes: true`

> The global kubeconfig has both contexts. Switch to Frostlink: `kubectx frostlink` / back to Artemis: `kubectx artemis`

## Tools Available This Session

### MCPs

Servers are registered in `.mcp.json` as three tiers — `litellm-general`, `litellm-media`,
`litellm-ops`. Tool names are `mcp__<server>__<tool>`, but **the server prefix changes when
the gateway is rewired**, so list the session's tools and match the suffix rather than
trusting a name written here.

| Tier      | Tool suffix   | Capability                                                 |
| --------- | ------------- | ---------------------------------------------------------- |
| `-ops`    | `k8s-*`       | kubectl — pods, logs, exec, resources, events, scale       |
| `-ops`    | `forgejo-*`   | Forgejo API — PRs, issues, files, repos, runners           |
| `-ops`    | `github-*`    | GitHub API — code search, file fetch, repo operations      |
| `-ops`    | `ha-*`        | Home Assistant — Artemis-local, not Frostlink              |
| `-general`| `searxng-*`   | Web search + URL fetch (use instead of WebSearch)          |
| `-media`  | `arr-*`       | Arr stack — Artemis-local, not Frostlink                   |
| plugin    | `memini`      | Cross-session semantic memory                              |

> Local `kubectl` and `talosctl` are already scoped to this cluster — `.mise.toml` sets
> `KUBECONFIG`/`TALOSCONFIG` to this repo's own files, so anything run from this directory
> hits Frostlink. No `--context` flag needed.
>
> The **MCP** k8s tools are the exception: they execute server-side and cannot see this
> repo's kubeconfig, so they act on whatever context the gateway holds (`artemis`). Prefer
> local `kubectl` here, and treat an MCP k8s result as Artemis's state unless verified.

### just commands

```bash
just kube apply-ks <ns> <ks>              # apply a Kustomization live (always before commit)
just kube sync <ocirepo|hr|ks|es|gitrepo> # force-sync a Flux resource type
just kube render-local-ks <ns> <ks>       # validate with flate (offline, no cluster needed)
just kube backup <ns> <claim>             # on-demand Kopiur snapshot, waits for it
just kube restore <ns> <ks> <claim>       # restore a PVC from Kopiur (DESTRUCTIVE)
just talos schematic-id                   # get current schematic ID from Sidero factory
just talos upgrade <version>              # upgrade Talos (reboots single node)
```

### Skills

Runbooks live in `.agents/skills/`; `.claude/skills/<name>` symlinks to each one. Every
`SKILL.md` carries `name:`/`description:` frontmatter — that is what lets a skill be invoked
automatically instead of only when its name is typed, so a skill added without it is
invisible. See the global `add-agent-content` skill before adding one.

Project skills (this cluster):

| Say this...                                                      | Skill              |
| ---------------------------------------------------------------- | ------------------ |
| "deploy X", "add app X", "set up X in namespace Y"               | `deploy-app`       |
| "flux is broken", "HelmRelease stuck", "kustomization failing"   | `fix-flux`         |
| "find examples for X", "how do others deploy X"                  | `kubesearch`       |
| "review X deployment", "audit X manifests"                       | `review-app`       |
| "cluster status", "what's broken", "health check"                | `cluster-status`   |
| "watch the deploy", "monitor rollout", "loop watch"              | `watch-deploys`    |
| "apply talos config", "upgrade talos node", "extension change"   | `talos-ops`        |
| "validate manifests", "flate diff", "pre-commit check"           | `flux-validate`    |
| "manage apoci federation", "webfinger", "federation peer"        | `apoci-federation` |
| "towonel is down", "create an invite", "expose X through towonel" | `towonel-ops`      |

Global skills in `~/.claude/skills/`, available here and in every other repo — not duplicated
per cluster: `forgejo`, `triage-renovate`, `build-container`, `playwright`, `add-agent-content`.

---

## Always-Loaded Instructions

@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md

---

## Topic References (load on demand)

| File                          | Contents                                                      |
| ----------------------------- | ------------------------------------------------------------- |
| `references/anubis.md`        | Anubis PoW scraper deterrence — component, GoToSocial policy, caveats |
| `references/flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race |
| `references/storage.md`       | openebs-zfs storage, zfs-snapshotclass, Kopiur backup component |
| `references/networking.md`    | Gateways, OCI VCN rules, Cloudflare tunnel, Tailscale         |
| `references/talos.md`         | Oracle Cloud Talos config, single-node quirks, upgrade steps  |
| `references/bootstrap.md`     | Bootstrap order and one-time setup                            |
| `references/database.md`      | Shared Postgres, pgbouncer tuning, surviving a primary restart |
| `references/towonel.md`       | towonel hub/edge — ports, grey-cloud DNS, key material, kopiur movers |

---

## Critical Rules

- **No SOPS** — secrets via 1Password ExternalSecrets only (`ClusterSecretStore: onepassword-connect`)
- **No TZ env var** — k8tz handles timezone cluster-wide; never set `TZ` in pod specs
- **No shared OCIRepository** — every app gets its own standalone OCIRepository
- **No external hostnames for cluster traffic** — always `<app>.<namespace>.svc.cluster.local`
- **Routes in HelmRelease values** — `HTTPRoute` goes in helmrelease values, not standalone files
- **Test before commit** — `just kube apply-ks <ns> <ks>` then wait for explicit user confirmation
- **No `git add .` or `git add -A`** — stage specific files by name only
- **Single node** — no drain/uncordon needed; storage class is `openebs-zfs` (ZFS-backed, default); backups via Kopiur to Cloudflare R2
- **OCI quirk** — CoreDNS must forward to `169.254.169.254`, not `/etc/resolv.conf` (resolves to unreachable `127.0.0.53`)

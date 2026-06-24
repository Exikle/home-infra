# Frostlink — Claude Context

> **Full hardware/networking reference**: `AGENTS.md`
> **Behavioral rules and runbooks**: `.agents/`

## What Is This

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free ARM64 (ca-toronto-1). All external traffic via Cloudflare tunnel only — no direct ingress. Management via Tailscale. Every push to `main` reconciles immediately to production via Flux. **No staging cluster — test with `just kube apply-ks` before committing.**

## Cluster Map

| Namespace          | Key Apps                                                      | Status       |
| ------------------ | ------------------------------------------------------------- | ------------ |
| `kube-system`      | Cilium 1.17.4, CoreDNS 1.46.0                                 | ✓ running    |
| `cert-manager`     | cert-manager 1.20.2                                           | ✓ running    |
| `external-secrets` | External Secrets 2.6.0, 1Password Connect 2.4.1               | ✓ running    |
| `flux-system`      | flux-operator 0.52.0, Flux v2.8.8                             | ✓ running    |
| `network`          | Envoy Gateway, wildcard cert, cloudflare-tunnel               | ✓ running    |
| `fediverse`        | GoToSocial (social.frostlink.dev), phanpy, apoci (registry)   | ✓ running    |
| `apoci`            | apoci OCI registry — federation peer for Artemis              | ✓ running    |
| `monitoring`       | Gatus / Uptime Kuma                                           | planned      |

## Node

**Single node `frostlink`** — ARM64 Ampere A1, 4 OCPU / 24 GB RAM  
Tailscale: `100.67.108.103` | Public IP: `40.233.88.33` | kubeconfig context: `frostlink`  
Talos v1.13.4 | Kubernetes v1.36.1 | `allowSchedulingOnControlPlanes: true`

> The global kubeconfig has both contexts. Switch to Frostlink: `kubectx frostlink` / back to Artemis: `kubectx artemis`

## Tools Available This Session

### MCPs

| MCP                                   | Capability                                                      |
| ------------------------------------- | --------------------------------------------------------------- |
| `mcp__artemis-ops__mcp-k8s_*`         | kubectl — pods, logs, exec, resources, events, scale            |
| `mcp__artemis-ops__mcp-forgejo_*`     | Forgejo API — PRs, issues, files, repos, runners                |
| `mcp__artemis-ops__mcp-github_*`      | GitHub API — code search, file fetch, repo operations           |
| `mcp__artemis-general__mcp-searxng_*` | Web search + URL fetch (use instead of WebSearch)               |
| `mcp__memini__*`                      | Cross-session semantic memory                                   |
| `mcp__artemis-ops__mcp-ha_*`          | Home Assistant (Artemis) — available but not local to Frostlink |
| `mcp__artemis-media__mcp-arr_*`       | Arr stack (Artemis) — available but not local to Frostlink      |

> MCP kubeconfig default is `artemis` context — always specify `--context frostlink` or switch with `kubectx frostlink` before running cluster commands.

### just commands

```bash
just kube apply-ks <ns> <ks>              # apply a Kustomization live (always before commit)
just kube sync <ocirepo|hr|ks|es|gitrepo> # force-sync a Flux resource type
just kube render-local-ks <ns> <ks>       # validate with flate (offline, no cluster needed)
just talos schematic-id                   # get current schematic ID from Sidero factory
just talos upgrade <version>              # upgrade Talos (reboots single node)
```

### Skills — invoke by natural language

| Say this...                                                      | Skill              |
| ---------------------------------------------------------------- | ------------------ |
| "deploy X", "add app X", "set up X in namespace Y"               | `deploy-app`       |
| "flux is broken", "HelmRelease stuck", "kustomization failing"   | `fix-flux`         |
| "find examples for X", "how do others deploy X"                  | `kubesearch`       |
| "review X deployment", "audit X manifests"                       | `review-app`       |
| "create Forgejo repo", "set action secret", "check runner"       | `forgejo`          |
| "cluster status", "what's broken", "health check"                | `cluster-status`   |
| "watch the deploy", "monitor rollout", "loop watch"              | `watch-deploys`    |
| "triage renovate PRs", "which updates are safe to merge"         | `triage-renovate`  |
| "apply talos config", "upgrade talos node", "extension change"   | `talos-ops`        |
| "validate manifests", "flate diff", "pre-commit check"           | `flux-validate`    |
| "manage apoci federation", "webfinger", "federation peer"        | `apoci-federation` |
| "add a new skill", "document this as a runbook"                  | `add-agent-content`|
| "build a custom image", "no upstream image"                      | `build-container`  |
| "automate browser", "playwright", "inspect UI calls"             | `playwright`       |

---

## Always-Loaded Instructions

@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md

---

## Topic References (load on demand)

| File                          | Contents                                                      |
| ----------------------------- | ------------------------------------------------------------- |
| `references/flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race |
| `references/storage.md`       | openebs-zfs storage, zfs-snapshotclass, Kopiur backup component |
| `references/networking.md`    | Gateways, OCI VCN rules, Cloudflare tunnel, Tailscale         |
| `references/talos.md`         | Oracle Cloud Talos config, single-node quirks, upgrade steps  |
| `references/bootstrap.md`     | Bootstrap order and one-time setup                            |

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

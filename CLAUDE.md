# Frostlink — Claude Context

> **Full reference in `AGENTS.md`** — hardware, networking, namespaces, bootstrap order.
> **Behavioral rules and task runbooks in `.agents/`** — read relevant files before working.

## Identity

- **User**: exikle (Dixon) — Mississauga ON (Eastern Time)
- **Cluster**: Frostlink on Talos Linux (Oracle Cloud ARM64)
- **GitOps**: Flux CD + Flux Operator | **Secrets**: 1Password ExternalSecrets
- **Domain**: `frostlink.dev` | **Repo**: <https://git.dcunha.io/Exikle/frostlink>
- **CNI**: Cilium | **Ingress**: Envoy Gateway (Gateway API / HTTPRoute)

---

## Always-Loaded Instructions

@.agents/instructions/cluster-conventions.md
@.agents/instructions/yaml-conventions.md
@.agents/instructions/commit-style.md
@.agents/instructions/session.md

---

## Topic References (load on demand)

For topic-specific patterns, read from `.agents/references/`:

| File                          | Contents                                                      |
| ----------------------------- | ------------------------------------------------------------- |
| `references/flux-patterns.md` | Flux reconciliation, cross-namespace gotchas, CRD timing race |
| `references/storage.md`       | local-path, future storage options                            |
| `references/networking.md`    | Gateways, VCN security rules, Cloudflare                      |
| `references/talos.md`         | Oracle Cloud Talos config, single-node notes                  |

## Skills

Use `.agents/skills/` for repeatable tasks — invoke via the Skill tool or a `/slash-command`.

---

## Critical Rules

- **No SOPS** — secrets via 1Password ExternalSecrets only (`ClusterSecretStore: onepassword-connect`)
- **No TZ env var** — k8tz handles timezone cluster-wide; never set `TZ` in pod specs
- **No shared OCIRepository** — every app gets its own standalone OCIRepository
- **No external hostnames for cluster traffic** — always `<app>.<namespace>.svc.cluster.local`
- **Routes in HelmRelease values** — `HTTPRoute` goes in helmrelease values, not standalone files
- **Test before commit** — verify on live cluster, get user confirmation, then commit

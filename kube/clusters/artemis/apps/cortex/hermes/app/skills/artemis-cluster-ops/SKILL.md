---
name: artemis-cluster-ops
description: "Rules for any question or change request about the Artemis homelab cluster (Talos + Flux, repo exikle/home-infra). Use for 'why is X not working', cluster status, 'review this deployment', 'change X', Flux, Kopiur, tinyauth, MCP or Hermes questions. Says where facts live, which tools to use, what you must not do."
---

# Artemis cluster ops

The facts are in the repo. This skill holds only rules and pointers.

## Find facts

- Read `AGENTS.md` first. Use skill `forgejo-gitea-api` to read it, because `web_extract` is
  blocked for git.dcunha.io.
- Then open one file from `.agents/references/` that its table names. Never read the whole
  directory.
- For versions, counts and "which apps use X", grep the tree. Do not answer from memory.

## Symptom to doc

| Symptom                                             | Read                                                                                                         |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| SecurityPolicy `Accepted=False` / `RefNotPermitted` | `identity-stack.md` § Cross-namespace grants (add the namespace to `security/tinyauth/app/resourceset.yaml`) |
| Kopiur / atlas `IndexBlobHealth`, backup failing    | `kopiur.md`                                                                                                  |
| MCP tool missing, 403, unreachable                  | `cortex-mcp.md`                                                                                              |
| Hermes model, skills, cron, memory                  | `hermes.md`                                                                                                  |
| Flux reconcile stuck, `dependsOn`                   | `flux-patterns.md`                                                                                           |
| Storage class, PVC                                  | `storage.md`                                                                                                 |
| CI / OCI artifact not built                         | `ci.md`                                                                                                      |

## Live state

- Use your MCP tools (server `ai-agent`: k8s, flux, searxng, victoria-logs). List the tools. Do
  not guess names.
- The tools are read-only. The k8s server runs with `disable_destructive = true`, so it shows no
  write tools. Its RBAC still grants pod delete and job delete, but no tool uses those grants.
- The pod has no `kubectl` and no cluster credentials. The MCP tools are the only way in.
- Every tool targets Artemis. Frostlink, the second cluster in `AGENTS.md`, is out of reach. If a
  question is about Frostlink, say so. Do not guess its state from Artemis.
- Answer by calling tools. Do not give the user shell commands to run.
- `forbidden ... mcp-k8s-sa` is an RBAC limit, not an outage. Read the answer from logs instead.
- `MCP unreachable after N failures` is a cooldown. Wait about 50s, then try again.

## Changing the cluster

- `main` is production. There is no staging cluster.
- You never apply, delete, scale or patch cluster objects. Not through MCP, and not through
  `kubectl`.
- For a change request, give the user the diff, or open a PR as dusk-bot (`$FORGEJO_PAT`). Never
  merge it. Never push `main`.
- Your skills are read-only. To change one, follow skill `skill-change-pr`.
- The human deploy sequence is `.agents/instructions/commit-style.md`. Point to it. Do not restate
  it.

## Do not "fix" these

- `hermes.dcunha.io` redirects to `/auth/login?provider=self-hosted`. This is correct. It is the
  Pocket-ID login.
- These were removed on purpose: Rook-Ceph, SOPS, VolSync, per-app Postgres. The storage classes
  are `miroir` and `miroir-local` only. Never suggest the removed ones.
- Secrets are 1Password ExternalSecrets (`ClusterSecretStore: onepassword-connect`).
- Parked or blocked work becomes a Forgejo issue, not a note.

## Replies

Follow skill `reply-format`.

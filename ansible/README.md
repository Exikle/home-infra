# ansible/ — host configuration

This directory holds every machine in the house that has an _operating system_ to configure: the
Proxmox host `pantheon`, the TrueNAS box `atlas` and the Forgejo LXC.

Flux cannot see this directory. The root Kustomization is scoped to `./kube/clusters/<cluster>/apps`.
Flux never reconciles anything here into the cluster.

## What does NOT belong here

- Talos nodes. Talos is immutable and you control it through its API. It has no SSH and no package
  manager. Its machine configuration is already the declarative state. Use
  `mise run //kube/clusters/artemis/talos:render-config`.
- Anything inside Kubernetes. Flux owns that.
- Restore drills and runbooks. They are interactive procedures with branches. They stay as mise
  tasks and in `.agents/skills/`.

## Usage

These are the playbooks:

- `atlas` (TrueNAS)
- `pantheon` (the Proxmox host)
- `forgejo` (the Forgejo LXC)
- `grimoire` (the macOS workstation)
- `ucg-max` (the Tailscale subnet router on the UniFi gateway)

`crs309` is in the inventory, but it has no playbook. OpenTofu owns its configuration
(`terraform/stacks/mikrotik`).

```bash
mise run //ansible:deps               # install pinned Galaxy collections
mise run //ansible:playbooks          # list playbooks
mise run //ansible:lint
mise run //ansible:syntax-check
mise run //ansible:check <playbook>   # --check --diff, changes nothing
mise run //ansible:apply <playbook>   # prompts for confirmation
```

Always run `check` before `apply`. Modules without check-mode support skip, or they report wrong
results. So a clean check run is a strong sign, but it is not proof.

A `[confirm]` prompt stops `apply` until you answer. For a non-interactive run, use
`mise run --yes //ansible:apply <playbook>` to skip the prompt.

Run these commands in a real terminal. Ansible refuses non-blocking stdio. Some non-interactive
paths give exactly that, for example the `!` prefix of Claude Code. The run then stops with
`ERROR: Ansible requires blocking IO`. It can stop _after_ it changes the host, and without running
its handlers. If you must run it that way, redirect the output to a file (`> out 2>&1`). Treat that
error as a partial apply, not as a no-op.

## Secrets

Secrets come from 1Password through the `community.general.onepassword` lookup. Give the vault, the
item and the field as separate values, not as an `op://` URI:

```yaml
forgejo_runner_token: "{{ lookup('community.general.onepassword',
    'forgejo', field='RUNNER_TOKEN', vault='infrastructure') }}"
```

Under a service-account token, the `op://vault/item/field` URI form fails with
`'vault' is required with 'service_account_token'`. It works only in an interactive session. Laptop
runs use a service-account token, so the URI form fails in the common case. This file documented
the URI form until 2026-09-07.

Tasks run under `op run`. So you need a service-account token or an active `op` session. Do not
add ansible-vault or SOPS. This repo deliberately has exactly one secrets system. Put
`no_log: true` on tasks that use secrets.

Host secrets go in the `infrastructure` vault. The 1Password Connect token on each cluster can read
`infrastructure` as well as its own vault. So today, every vault is in reach of a cluster
(`terraform.md`, "Vault placement").

## Apply by hand, not from CI

Ansible pushes changes, and it is not transactional. A half-applied run against the only hypervisor
in the house leaves it in an unknown state. No reconcile loop exists to repair it. Flux can apply
all the time because Kubernetes repairs itself. Bare metal does not.

Nothing runs Ansible in CI. Run the lint and the syntax check by hand. A human applies from the
laptop.

## Collections

`requirements.yml` sets minimum versions (`>=`) for the collections, not exact pins. The `proxmox_*` modules were split out of
`community.general` into `community.proxmox`. The old paths are deprecated redirects. Write new
code against `community.proxmox`.

`collections/` is gitignored. `requirements.yml` is the tracked source of truth.

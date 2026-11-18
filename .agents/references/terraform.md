# OpenTofu — home-infra

This file covers the `terraform/` tree. That tree holds everything in the house that has an API
and creates objects. `terraform/README.md` covers day-to-day use. This file gives the reasons, the
provider choices, and the traps.

## The ownership boundary

> Tofu owns everything up to and including the Talos VM.
> Flux owns everything inside the cluster.
> Ansible owns the mutable Linux boxes that are not Talos.

Every failure that people reported with this layout comes from two tools that own one object.
Flux reconciles all the time. Tofu reconciles only when someone runs it. An object that both tools
own drifts forever. Flux reverts it, the next tofu plan shows the diff, and the cycle repeats.

Never add the `kubernetes` or `helm` providers. They cause the problem of two owners. Also,
`kubernetes_manifest` needs a live API server at plan time. So plans break when the cluster is
down. That is when you most need to reason about the infrastructure under it.

## Why OpenTofu and not Terraform

OpenTofu uses the MPL-2.0 licence, not BUSL. It also has native encryption of state and plans.
Terraform does not have this, and this repo depends on it. Every provider below resolves on
`search.opentofu.org`.

## Provider choices, and why

| Target   | Provider                      | Notes                                                |
| -------- | ----------------------------- | ---------------------------------------------------- |
| Proxmox  | `bpg/proxmox`                 | The maintained one. Not `Telmate/proxmox`, a legacy. |
| UniFi    | `ubiquiti-community/unifi`    | See below. The original is archived.                 |
| RouterOS | `terraform-routeros/routeros` | The CRS309, stack `mikrotik`. Read the traps first.  |
| TrueNAS  | `truenas/truenas`             | Official. Read the traps first.                      |

### UniFi — the provider situation

`paultyng/terraform-provider-unifi` (581★) is archived and read-only. Two live forks exist, and
you cannot use one in place of the other:

- `ubiquiti-community/unifi`: an org owns it. It continues the v0.41.x line, so it is a drop-in
  replacement for existing paultyng state. It exposes `firewall_zone` and `firewall_policy`. Only
  this fork exposes `bgp`, `wan`, `traffic_route`, `vpn_*`, and `wireguard_peer`.
- `filipowm/unifi`: one maintainer owns it. It moved to a v1.x with a schema that is not
  compatible. It has more typed `setting_*` singletons, but no BGP, WAN, or traffic routes.

We use `ubiquiti-community`, because more than one person maintains it and it covers more of the
UCG-Max.

### Proxmox — when SSH is actually needed

The provider works through the API first. It needs SSH only for these tasks:

- Upload of snippets
- Some file content types
- Import of a disk through `source_file.path`
- Container `idmap` entries

VM/LXC CRUD, storage, pools, users, and `download_file` all use only the API.

Talos does not use cloud-init. So you can avoid the snippet path, and with it SSH, fully. Use
`proxmox_virtual_environment_download_file` to pull the Talos image, then `..._vm`. The machine
configuration does not belong to tofu. It comes from the `//kube/clusters/artemis/talos` tasks and
the node templates.

GPU passthrough (`hostpci`) works, but any change to it force-stops the VM. Raw PCI IDs have better
support than the newer resource-mapping style.

## State — committed to this repo, always encrypted

The state lives in git, next to the stack that owns it
(`terraform/stacks/<name>/terraform.tfstate`). The native state encryption of OpenTofu encrypts it
(`aes_gcm` keyed by `pbkdf2`, 600k iterations, sha512).

Why the state is in the repo and not on a share: the team considered an NFS dataset on `atlas`
and rejected it. `backend "local"` cannot tell "the state file is missing" from "the mount is not
there". WSL2 does not remount reliably across restarts. If the NFS mount drops, tofu silently
writes a fresh empty state into the empty mountpoint. The next apply then tries to rebuild
infrastructure that already exists. Git has no such silent failure. The file is in the working
tree or it is not, and git tells you which.

Git also gives what the team wanted from the share:

- Copies off the machine (Forgejo)
- Exact history (`git log` on the state file)
- Rollback (`git checkout <sha>`)

Why the state is not in the cluster: tofu creates the Talos VMs. The storage of the cluster runs on
those VMs. So the cluster holds the state that describes them. If the cluster dies, you cannot
plan a rebuild. The same loop applies to the shared CNPG Postgres through the `pg` backend.

### How the passphrase gets in

The hidden `run` task in `terraform/mise.toml` reads the passphrase from 1Password at run time. It
builds `TF_ENCRYPTION` in the environment. It never writes the passphrase to a file. It never
passes the passphrase through the `onepassword` provider. Providers start after OpenTofu evaluates
the encryption block. That route stores the state key inside the state that it encrypts.

To override the reference, set `TOFU_PASSPHRASE_REF`. To give the literal value, set
`TOFU_PASSPHRASE`. Use the literal value to test the mechanism without 1Password. The tasks refuse
to run with a passphrase shorter than 16 characters.

Vault placement: the reference points at `op://infrastructure/tofu-state/password`.
`infrastructure` is in the read set of the in-cluster Connect token. The vault order is in
`clustersecretstore.yaml`. So a cluster compromise reaches the passphrase. That passphrase
decrypts the state that describes the hypervisor that the cluster runs on. The move of the
passphrase out of every vault that a cluster can read is still owed
([#3384](https://git.dcunha.io/Exikle/home-infra/issues/3384)).
The change is one line here, because the reference is a variable and not a hardcoded path.

The vaults are split by blast radius (who can read them), not by tool. A split into `ansible` and
`terraform` vaults duplicates credentials such as the Proxmox token, and duplicates drift.

If you lose the passphrase, every state file is lost. There is no recovery path. The ciphertext
is all there is. Keep a copy of the passphrase in a second vault.

### The guard that makes this safe

Committed state is safe only while it is ciphertext. For this reason, `hooks/tfstate_encrypted.py`
runs as a pre-commit hook on every staged `*.tfstate`, and it refuses plaintext. It passes only a
document that has a non-empty `encrypted_data` key. So a shape that it does not know fails closed.
It also rejects an empty file, which is the sign of a backend path that pointed to the wrong place.

This is important because `mise run //terraform:...` sets `TF_ENCRYPTION`, but a bare
`tofu apply` does not. The team tested both paths. The task writes ciphertext. A bare apply writes
plaintext, and the hook catches it.

`.gitignore` does not ignore `*.tfstate`, on purpose, because git must track it. Each cluster's
Flux OCI artifact holds only `kube/base/`, `kube/components/` and that cluster's own Flux folders, so
tracked state never goes to the registry.
`.sourceignore` also excludes `terraform/`, for a build that packs the full repo.

### If plaintext state ever gets committed

Treat every credential in it as compromised. Rotate the credentials. Then rewrite the history to
remove the blob. Do not only delete the file in a later commit. The blob stays in the object store
and in every clone.

## Adopting existing infrastructure

Everything in this house already exists. So every stack is an import task, never a create task.

1. Write the resource block.
2. Run `mise run //terraform:import <stack> <address> <id>`.
3. Run `mise run //terraform:plan <stack>`. Repeat until it reports no changes.

A clean plan after the import is the only real sign of success. If the plan wants to change
something that you did not intend, the resource block is wrong. Fix it, and do not apply.

## Traps

- UniFi can lock you out. A bad firewall apply cuts the path that you apply over. Plan first,
  every time, and keep a console or a recovery route.
- `unifi_user` churn: UniFi creates a user object for every client that ever associated. It keeps
  changing that object (hostname, note, last-seen). DHCP reservations managed this way give diffs
  that never stop. Set `allow_existing = true` and `skip_forget_on_destroy = true`. In practice
  they are mandatory.
- The UniFi site ID is the short hex slug, not `Default`. If you use the wrong value, the provider
  silently targets the wrong site.
- Do not manage DNS records here. external-dns owns them: `external-dns-unifi` for the LAN, and
  `external-dns-cloudflare` / `external-dns-edge` / `external-dns-frostlink` for Cloudflare
  (`networking.md` § External DNS). Each record set has one owner.
- BGP is out of scope, on purpose. The `ubiquiti-community` provider can manage AS 64533, but the
  full cluster network depends on that peering. It stays manual.
- TrueNAS dataset `type` and `compression` are case-sensitive, and `type` is ForceNew. The
  examples of the official provider say `"FILESYSTEM"` / `"LZ4"`. atlas reads back
  `"filesystem"` / `"lz4"` (imported on 25.04, still lowercase on 25.10). The uppercase spelling
  plans a destroy and recreate of every dataset. Use lowercase. Never apply a plan that proposes a
  replacement.
- TrueNAS uses HTTPS on port 1443, not 443. It sets `ui_httpsport = 1443`, with plain HTTP on 80.
  So the endpoint is `wss://10.10.99.100:1443/api/current`. Port 443 refuses the connection.
- The OpenTofu registry has no GPG key for `truenas/truenas`. So `init` installs it without a
  signature check. The Terraform registry does check it. For this reason, `versions.tf` pins the
  exact version. `terraform-routeros/routeros` has the same problem and the same exact pin.
- RouterOS needs api-ssl with a real certificate. The CRS309 shipped with `certificate=none`. A
  self-signed certificate fails with `CA not found`. RouterOS needs a local CA (`tofu-ca`) that
  signs the server certificate (`tofu-api`). Keep both out of the stack.
- You cannot import RouterOS `/ip service` on 7.20. The provider keys it by name, and each live
  ssh/winbox session shows as another row with the same name.
- Do not manage RouterOS `/system clock`. Its generated resource pins the literal date and time,
  so an apply sets the clock back.
- RouterOS `/interface ethernet` always plans an in-place update after import. `factory_name` is
  required, and the import cannot fill it. That update sends every port setting again. Do not do
  that to sfp1 (UCG uplink) or sfp8 (pantheon) in the daytime.

## Renovate

`.renovaterc.json5` scopes the `terraform` manager to `terraform/**/*.tf`. Provider updates do not
automerge, on purpose, because they change real hardware. This is important because the inherited
`home-operations` preset sets no `enabledManagers` and extends `config:recommended`. So every
manager is on by default.

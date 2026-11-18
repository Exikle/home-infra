# terraform/ — OpenTofu

This directory holds everything in the house that has an API and creates objects: Proxmox VMs and
LXCs, UniFi networks, the bridge, VLANs and routes of the MikroTik switch, and TrueNAS datasets
and shares. Run `ls terraform/stacks` for the list of stacks.

Flux cannot see this directory. CI builds the artifact of each cluster from `kube/` only
(`.forgejo/workflows/oci-push.yaml`). So Flux never reconciles anything here into the cluster.

## The ownership rule

> Tofu owns everything up to and including the Talos VM.
> Flux owns everything inside the cluster.
> Ansible owns the mutable Linux boxes that are not Talos.

Never let two tools own the same object.

## Layout

```text
modules/          shared reusable modules
stacks/<name>/    one stack per blast radius, each with its own state
```

Each stack has its own state. So a UniFi mistake cannot corrupt the Proxmox state, and a DNS
change does not refresh every provider in the house.

## Usage

```bash
mise run //terraform:stacks              # list stacks
mise run //terraform:init <stack>
mise run //terraform:plan <stack>        # always, before apply
mise run //terraform:apply <stack>       # prompts for confirmation
mise run //terraform:import <stack> <address> <id>
mise run //terraform:fmt
```

Every task reads the passphrase for state encryption from 1Password. It gives the passphrase to
tofu as `TF_ENCRYPTION`. To test without 1Password, set `TOFU_PASSPHRASE` directly. To point at a
different item, set `TOFU_PASSPHRASE_REF`.

## State

The repo holds the state, encrypted with the native state encryption of OpenTofu.
`terraform/stacks/<name>/terraform.tfstate` is a tracked file, and it is always ciphertext.

The hidden `run` task in `terraform/mise.toml` reads the passphrase from 1Password at run time. It
gives the passphrase to tofu as `TF_ENCRYPTION`. The passphrase never goes into a file.

A pre-commit hook (`hooks/tfstate_encrypted.py`) refuses to commit plaintext state.
`mise run //terraform:...` sets up the encryption. A bare `tofu apply` does not. Use the tasks. If
you forget, the hook catches the mistake.

If you lose the passphrase, every state file is lost. Keep a copy of the passphrase in a second
vault. Today the tasks read it from `op://infrastructure/tofu-state/password`. Its move out of the
vaults that a cluster can read is still owed
([#3384](https://git.dcunha.io/Exikle/home-infra/issues/3384)).

The full reasons, including why the team rejected an NFS share on `atlas`, are in
`.agents/references/terraform.md`.

## Adding a stack

1. Run `mkdir stacks/<name>`. Write `main.tf`, `providers.tf` and `versions.tf`.
2. Declare `backend "local" {}`. The state goes beside the stack, and you commit it.
3. Import the existing objects. Do not create them. Success is a `tofu plan` that reports no
   changes.
4. If the stack adds a provider, write down the reason in `.agents/references/terraform.md`
   § Provider choices, and why.

## Warning: UniFi

Always plan first, and keep a console or a recovery path ready. A bad firewall apply can cut the
network path that you apply over, and lock you out of your own network.

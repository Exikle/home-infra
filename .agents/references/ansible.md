# Ansible — home-infra

This file covers the `ansible/` tree. That tree holds every machine in the house that has an
_operating system_ to configure. `ansible/README.md` covers how to run it. This file gives the
reasons and the traps.

## Scope — what belongs here

| Host                      | What Ansible owns                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pantheon` (10.10.99.104) | The Proxmox host OS: ZFS dataset properties (`roles/zfs`), `node_exporter`, tap and net tuning, `lldpd`, the Sunday pre-update snapshot of CT 105 (`roles/pve_guest_snapshots`), and the nightly off-site mirror of `/bulkpool/backups` to atlas (`roles/offsite_backup`). `playbooks/pantheon.yml` applies only these. Some files are managed by hand on the host and are in no repo: apt `.sources`, `sshd_config.d/10-hardening.conf`, `modprobe.d/zfs.conf` (ARC cap), the ZED→Alertmanager zedlet, `smartctl_exporter.service`, `/etc/pve/notifications.cfg`, the `pve-etc-backup` timer, `/etc/network/interfaces`, and the PCI mappings. There is no NUT (no UPS) and no `ssacli` (the HBA is LSI, not Smart Array). These files must still move into roles. Until then, the daily `/etc` tarball on `bulkpool` is the only copy. |
| `atlas` (10.10.99.100)    | TrueNAS: the netdata `[web]` bind in `/etc/netdata/netdata.conf` and its POSTINIT restore hook (`roles/netdata_exporter`). `playbooks/atlas.yml` applies only these. Tofu owns the datasets, the NFS shares and the snapshot and scrub tasks (`terraform/stacks/truenas`). Neither tool manages the `media` SMB share. `terraform/stacks/truenas/main.tf` gives the reason.                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `forgejo` (10.10.99.24)   | The Forgejo LXC (CT 105, created by tofu in `terraform/stacks/proxmox/forgejo.tf`): the OS baseline (`roles/lxc_base`), the release binary, `app.ini`, the systemd unit and the scripts (`roles/forgejo`, `playbooks/forgejo.yml`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `grimoire` (10.10.1.157)  | The MacBook workstation: `roles/macos_workstation`, `playbooks/grimoire.yml`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `ucg-max` (10.10.99.1)    | The UCG Max gateway: the Tailscale subnet router (`roles/ucg_tailscale`, `playbooks/ucg-max.yml`). See the UCG Max section below. UniFi owns everything else on the box.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `crs309` (10.10.99.2)     | The Mikrotik switch: inventory only, no playbook. Tofu owns its configuration (`terraform/stacks/mikrotik`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |

## What does NOT belong here

- Talos nodes. They have no SSH, no package manager and no Python interpreter. A `command:`
  wrapper around `talosctl` uses Ansible as a shell script, and it gives none of the value of
  Ansible. The Talos machine configuration _is_ the declarative state
  (`mise run //kube/clusters/artemis/talos:render-config`).
- Anything inside Kubernetes. Flux owns it.
- Restore drills and runbooks. They are interactive procedures with branches, and they need human
  judgment. That is the opposite of convergent state. They stay as mise tasks and in
  `.agents/skills/`.
- Windows and Arcana. Arcana is one desktop that you manage through its GUI. The WinRM setup costs
  more than it saves.
- The WSL2 dev machine. mise owns both its dotfiles and its tools. mise manages the dotfiles with
  `symlink-each` in `~/dotfiles/mise.toml`, and you apply them with
  `mise bootstrap dotfiles apply`. The only real gap is system configuration that needs sudo
  (`/etc/wsl.conf`, linuxbrew removal). The post-dotfiles hooks of mise cover that gap, so the box
  does not get a third owner.

## Collections

`ansible/requirements.yml` sets minimum versions (`>=`) for the collections, not exact pins. So
`mise run //ansible:deps` installs the newest release of each. It installs them into the
gitignored `collections` directory under `ansible`. In a fresh worktree, that directory does not
exist until you run the command.

No role uses a `proxmox_*` module today. If you add one, use `community.proxmox`, not the
deprecated redirects in `community.general`.

`arensb.truenas` is the only usable TrueNAS collection. It does _not_ call the REST API from the
control node. It runs on the box over SSH and calls `midclt` in a shell, so `atlas` needs SSH
access. It has no modules for replication tasks, cloud sync or Apps. It covers snapshot tasks but
not replication.

## The forgejo role — why `app.ini` is edited key-by-key

`roles/forgejo` builds a host from bare Debian, and it also converges an existing host. Since
2026-10-10, the role does these things:

1. It installs the packages.
2. It creates the `git` user at the pinned UID/GID (103/112). These are the IDs that the original
   community-scripts install used, so the data that came over keeps its owner.
3. It installs the latest release.
4. It creates an instance signing key if there is none.

The role never replaces an existing signing key. A new key breaks the verification of every
commit that the old key signed.

The play ends with an `/api/healthz` check. systemd reports "started" before Forgejo reads its
configuration. Without the check, a fatal configuration error passes. On a fresh instance,
someone must still create the admin account by hand.

The role converges the file with `community.general.ini_file`, one key at a time. It does not use a
template. This choice is deliberate. Understand it before you change the role. A `template:` task
renders the whole file, so it silently deletes every key that it does not reproduce. `app.ini`
contains at least one key whose value is recorded nowhere else: `[database] PASSWD`. It is a dead
MySQL leftover, and it has no effect under `DB_TYPE = sqlite3`. `ini_file` changes only the keys
that the role names. It leaves everything else byte-identical.

This choice has a real cost. The role does not converge keys that are absent from
`forgejo_settings`. The role cannot see drift in a setting that it does not manage. That is the
trade: the role leaves undeclared settings alone, and it does not destroy them.

`ini_file` never removes a key on its own. To remove a key, or to move a key to another section,
list its old location in `forgejo_settings_absent`. If you only delete it from `forgejo_settings`,
the old copy stays in `app.ini`.

### The secrets live in 1Password

Some `app.ini` values are secrets. They live in the `server` section of
`op://infrastructure/forgejo`. A second `ini_file` task with `no_log: true` applies them from
there. The list of `app.ini` keys and their 1Password fields is `forgejo_secret_settings` in
`roles/forgejo/defaults/main.yml`.

A separate 1Password item does not hide these secrets from the clusters. The 1Password Connect
tokens of both clusters can read the `infrastructure` vault, because the cluster's own Forgejo
tokens live there too. To keep the secrets from the clusters, you need a vault that Connect cannot
read. A separate item is not enough.

This instance does not set `SECRET_KEY`. You must not add it. The key is absent from `app.ini`, and
Forgejo uses its own default. If you add a value, it invalidates everything that Forgejo encrypted
under the old value.

The role applies these values and does not template them. So a `--check` run is a live
consistency test:

- If every entry of `forgejo_secret_settings` reports `ok`, the vault matches the box.
- If one reports `changed`, the vault and the host are different. Find out which one is correct
  before you apply.

### Themes are shipped by the role, and the THEMES list is derived

Forgejo shows a custom theme only when both of these are true:

1. `theme-<name>.css` exists in `$WORK_PATH/custom/public/assets/css/`.
2. `<name>` is in `[ui] THEMES`.

If only one is true, nothing tells you. There is no error, and Forgejo does not offer the theme.

For this reason, `forgejo_custom_themes` lists the filenames. `forgejo_theme_names` derives the
`app.ini` value from them: it removes the `theme-` / `.css` wrapper. To add a theme, you add one
line to one list. The two halves cannot drift apart.

The stylesheets live in `roles/forgejo/files/themes/`. Forgejo serves them directly from disk, so a
CSS change needs no restart. A change to the THEMES list does need a restart, because Forgejo reads
`app.ini` once at boot. The task notifies the restart handler. That works only when the play runs to
the end. For the case where it does not, see the partial-apply trap below.

These are the symptoms of a missed restart:

- The files are on disk.
- `THEMES` is correct in `app.ini`.
- The stylesheet serves `200`.
- The theme still does not appear in Settings.

The running process still holds the list that it read at boot. To find out, compare
`systemctl show forgejo -p ActiveEnterTimestamp --value` with the mtime of `app.ini`.

`anthracite` is the theme of Erwan Leboucher (`eleboucher/homelab`), and it is already in use here.
Each file is a compiled Forgejo base, followed by a trailing `:root` block. That block maps the
`--steel-*` (dark) or `--zinc-*` (light) colour ramp of the base onto a named palette. The trailing
block is the whole theme. The base above it is unchanged upstream output.

The base comes from an older Forgejo major. A newer major can add variables that the base never
defines. For example, Forgejo 17 builds `--color-thin-*` (callouts, danger buttons, coloured text)
from `--hue-*`. In light mode, it also uses `--thin-lightness` and `--regular-chroma`. A last
`:root` block in each file holds values for those variables. The host upgrades itself across
majors (see the cron table below). So after each Forgejo major upgrade, do these steps:

1. Get the running version with `curl -s https://git.dcunha.io/api/v1/version`.
2. Diff the variables that `index.css` references against the variables that `index.css` and each
   theme define.
3. Compare the result with the built-in `forgejo-dark`/`-light`.

`solarized` is the default theme. The team built it from `anthracite`: they replaced only the
trailing block with the 16 colours of Solarized (<https://ethanschoonover.com/solarized/>). The 16
colours are in each file as `--sol-<name>` variables, and every ramp is mixed from them.

In some places, Solarized measures below WCAG AA (4.5:1). So the theme has three deliberate
deviations:

- Links: Solarized blue `#268bd2` is 3.5:1 on the dark panels and 3.4:1 on the light background.
  `--color-primary` is a lighter blue in dark mode (`#54a0d3`) and a darker blue in light mode
  (`#1b6ea3`). Each one reaches 4.5:1 on both surfaces of its mode. The true blue stays on
  `--color-accent` for uses that are not text.
- Dark body text: Solarized uses `base0`, which is 4.1:1 on the `base02` panels. `--color-text` is
  `base1` (4.9:1). `base0` stays for secondary text.
- Light body text: Solarized uses `base00`, which is 4.1:1 on `base3`. `--color-text` is `base02`,
  and secondary text is `base01` (5.0:1). `base00` stays only for the faintest text.

### The host updates itself — do not let the role fight it

| Cron file                | When (UTC)  | What it does                                                                          |
| ------------------------ | ----------- | ------------------------------------------------------------------------------------- |
| `forgejo-update`         | Sun 03:00   | Installs the `latest` release from Codeberg, major versions too (the user chose this) |
| `forgejo-status-cleanup` | Daily 04:30 | Runs `forgejo doctor cleanup-commit-status`, then a 90-day age trim in SQLite         |

`forgejo-update.sh` and the role cannot both own the binary. If both own it, cron upgrades on
Sunday, the next Ansible run puts `forgejo_version` back, and this repeats forever. For
this reason, `forgejo_manage_binary` is false by default. An `assert` fails the play if it is true
at the same time as `forgejo_update_cron_enabled`. Pick one owner.

Since 2026-10-10, the updater makes an upgrade safe with these steps:

1. It verifies the `.sha256` of the release.
2. It flushes the queues.
3. It stops Forgejo.
4. It takes a `sqlite3 .backup` into `/var/lib/forgejo/backups` (it keeps the newest 3).
5. It swaps the binary.
6. It waits for `/api/healthz`.

If the health check fails, the updater puts back both the old binary and the pre-upgrade database.
So it also undoes the database migration of a major version.

There is a second safety layer. pantheon takes a snapshot of CT 105 at Sun 02:55 UTC
(`roles/pve_guest_snapshots`, `auto_*`, it keeps the newest 4). If both of the steps above fail,
`pct rollback 105 <name>` restores the whole container.

Other failures can happen while the service is stopped, for example a failed backup or a failed
start. In that case, the updater puts back the old binary and database if it already swapped them.
It starts Forgejo again, and only then sends an alert. So a failed run does not leave Forgejo down.

Both cron scripts set their own `PATH`, and the updater runs `set -E`. These two settings exist for
these reasons:

- The `PATH` of cron is `/usr/bin:/bin`, which has no `runuser`.
- Without `-E`, functions do not inherit the `ERR` trap. A failure inside `as_git` then exited with
  no alert and no restart.

On 2026-10-18, these two faults together left Forgejo stopped for 2.5 hours (#2809).

The updater reports every outcome. It posts `alertname=ForgejoUpdate` to Alertmanager. This is the
same path that the ZED bridge of pantheon uses, because chaski itself is cluster-internal. The
severity depends on the outcome:

- `info`: it upgraded.
- `warning`: it did not upgrade, but Forgejo still serves. The causes are no asset, a bad checksum,
  a rollback, or an unexpected exit while the service is up.
- `critical`: Forgejo is left down.

When there is nothing to do, the updater sends nothing. Info alerts expire after one hour. The other
alerts expire after one day.

The age trim stays raw SQL for this reason: `doctor cleanup-commit-status` of Forgejo removes only
duplicates. It has no age retention. CI writes several thousand statuses a day, so the 90-day
`DELETE` keeps the size of the table flat.

### `section: DEFAULT` is a trap in `ini_file`

`app.ini` starts with five keys (`APP_NAME`, `APP_SLOGAN`, `RUN_USER`, `WORK_PATH`, `RUN_MODE`)
above the first section header. `community.general.ini_file` does not treat `section: DEFAULT` as
that area. Instead, it adds a literal `[DEFAULT]` block to the end of the file and leaves the real
keys unchanged. The settings then silently have no effect. `section: null` edits the area before
the first section in place. A `--check --diff` run found this problem. That is why you must always
do one.

## Rebuilding the Forgejo container

This procedure replaces the container with a fresh one that tofu builds. The new container takes
over the identity of the old one.

1. Run `pct snapshot 105 <name>`.
2. In `terraform/stacks/proxmox/forgejo.tf`, set `vm_id = 106` and a free LAB address. Use the
   `.20`–`.49` range. It is outside DHCP (`.50`–`.70`) and outside the Cilium pool (`.71`–`.99`).
   You cannot use ARP to find a free address, because the UCG answers ARP for every unused address
   with its own MAC.
3. Run `mise run //terraform:plan proxmox`.
4. Run `mise run --yes //terraform:apply proxmox`.
5. Run `mise run --yes //ansible:apply forgejo -e ansible_host=<temp IP>`. It builds and starts a
   fresh instance. The copy in the next step overwrites that instance.
6. On pantheon, copy at the ZFS level with `rsync -aHAX --numeric-ids --delete`. Copy from
   `/vmpool/subvol-105-disk-0/{var/lib/forgejo,etc/forgejo,home/git}` into the rootfs and data
   volume of 106. Both containers are unprivileged with the same ID offset, so the file owners stay
   correct.
7. Keep Forgejo stopped on 106. A second live copy runs push mirrors and webhooks from old
   data.
8. Cut over. This step causes about 2 minutes of downtime:
    1. Stop Forgejo on 105.
    2. Make a final copy. Include `/etc/ssh/ssh_host_*`, so git clients see no host-key change.
    3. Shut down both containers.
    4. Use `zfs rename` on the subvols and `mv` on the configuration files: 105 → 905
       (`onboot: 0`, `link_down=1`), and 106 → 105 with the old MAC and IP.
9. Run the playbook again against `.24`. The copy brought the old `app.ini`, so the newer keys of
   the role are not live until the playbook runs.
10. Run `mise run //terraform:run proxmox state rm <address>`.
11. Set `vm_id = 105` and the final address and MAC.
12. Run `mise run //terraform:import proxmox <address> pantheon/105`.
13. Apply the state-only diff. Make sure that the next plan is empty. Never run a bare `tofu`. It
    skips `TF_ENCRYPTION` and writes the state unencrypted (`terraform.md`).
14. After the new container runs cleanly for two weeks, delete 905 (`pct destroy 905`).

## The UCG Max role — Tailscale on a box UniFi owns

UniFi has no native Tailscale. `roles/ucg_tailscale` installs the community package
[`SierraSoftworks/tailscale-unifi`](https://github.com/SierraSoftworks/tailscale-unifi), so that
the gateway can be a subnet router to the tailnet. The team applied it on 2026-10-02 against
Headscale. `host_vars/ucg-max.yml` sets `ucg_tailscale_up: true` and the login server. So a plain
`mise run //ansible:apply ucg-max` also brings the node up. It also applies again any pref that
drifted (routes, hostname, SNAT). The role default stays `ucg_tailscale_up: false`.

- The role pins a version. It does not use `curl | sh latest`. The role does what the upstream
  `install.sh` does: it unpacks the release tarball into `/data`, then runs `manage.sh install`.
  But it uses a pinned tag. The tarball has no version file, so the role writes
  `/data/tailscale/.tailscale-unifi-version`. To find the pinned tag, run
  `grep unifi_version: ansible/roles/ucg_tailscale/defaults/main.yml`. That pins only the
  _wrapper_. The `tailscale` .deb itself follows the upstream `TAILSCALE_AUTOUPDATE` (daily, on by
  default), unless you set `ucg_tailscale_package_version`.
- A firmware update can remove the install. The package lives in `/data`, which survives. But the
  `.deb` goes into the overlay root. The upstream `tailscale-install.timer` runs
  `manage.sh on-boot` after boot and once a day, and it installs the package again. This has
  failed before (upstream issues #38, #96, #118). So after every UniFi OS update, watch whether the
  tunnel is reachable. Do not trust the timer. The prefs (login server, routes) live in
  `/data/tailscale/tailscaled.state`, and they survive a reinstall.
- Configuration changes go through `manage.sh install!`, not `restart`. The `TS_*` lines in
  `tailscale-env` reach `/etc/default/tailscaled` only during install, so the handler runs
  `install!`. That runs apt, so the gateway needs internet access for the handler to succeed.
- `TS_TUN_DISABLE_TCP_GRO=1` works around the TSO engine of the UCG Max LAN port. That engine
  damages the GRO super-packets of Tailscale. Without the setting, subnet-router TCP drops to
  hundreds of kbps while ping looks normal (upstream issue #205).
- Kernel (TUN) mode is required. Userspace mode NATs everything, and it cannot route from the LAN to
  the tailnet. When `/dev/net/tun` is missing, upstream silently falls back to userspace. The role
  fails instead.
- `--snat-subnet-routes=false` keeps the real LAN source IPs on the far side. You must set it on
  _both_ subnet routers. Each router must also accept the routes of the other. If not, return
  traffic breaks (upstream issue #161). `--accept-dns=false` stops Tailscale from taking over the
  dnsmasq of UniFi.
- dnsmasq must also listen on `tailscale0`. If not, split DNS fails for every Headscale client.
  UniFi runs dnsmasq with `bind-dynamic` and an `interface=` list that holds only the LAN bridges.
  So dnsmasq ignores (UDP) or resets (TCP) a `dcunha.io` query that comes in over the tailnet. The
  role installs `dnsmasq-tailscale.{service,path}`. These units write `interface=tailscale0` to
  `/run/dnsmasq.dhcp.conf.d/zz-tailscale.conf`. They restart dnsmasq only when the file was
  missing. `/run` is tmpfs, so the path unit applies the file again after boot. It also does this
  each time UniFi rewrites its dnsmasq configuration. Each new apply causes a DNS gap of about 1 s
  on the LAN. To make sure that it works, run `ss -lun | grep ':53'` on the UCG. The output must
  list the `100.64.x` address.
- The role clamps TCP MSS across `tailscale0`. Without the clamp, Frostlink pods stall for about
  7 s on every TLS handshake to an Artemis LoadBalancer IP. This is the cause, from a packet
  capture on 2026-10-03:
    1. Pods have MTU 1500. Their SYNs leave the VPS through a BPF redirect that skips netfilter, so
       they advertise MSS 1460.
    2. Envoy on `.90`/`.98` then sends 1500-byte segments.
    3. The UCG answers `need to frag (mtu 1280)`, but the Cilium-LB VIP never acts on it.
    4. TCP recovers only after 1+2+4 s of retransmits.

    The role installs `tailscale-mss.{service,timer}`. They add two `mangle FORWARD` TCPMSS rules:
    `-i tailscale0` set to 1240, and `-o tailscale0` clamp-to-pmtu. iptables is not persistent, and
    UniFi rewrites its rules. So the timer adds the rules again every minute. To make sure that they
    are there, run `iptables -t mangle -S FORWARD | grep TCPMSS`.

- `tailscale up` is made idempotent by comparison. The role reads `tailscale status --json` and
  `tailscale debug prefs`. It runs `tailscale up --reset …` only when the node is logged out or a
  pref drifted. The 1Password lookup is in the `vars` of that task, so it resolves only when the
  task runs. A check run with `ucg_tailscale_up: false` does not need the item to exist.
- The tag comes from the pre-auth key, never from `--advertise-tags`. Create the key with
  `headscale preauthkeys create --user <id> --tags tag:home-router`. On a pre-auth-key
  registration, Headscale rejects _any_ requested tag, even one that is the same as the tag on the
  key. It fails with `requested tags [tag:home-router] are invalid or not permitted`, and the node
  stays logged out. The first real apply hit this on 2026-10-02. The failed attempt does not use up
  the key.
- The key in `infrastructure/headscale` → `ucg-max router` is single-use, and it is already used.
  The role reads it only when the node is logged out (a reset UCG, or a deleted Headscale node). In
  that case, run `mise run --yes //ansible:ucg-authkey <user-id>` before you run the role again.
  This task makes a 1-hour key on Frostlink. It writes the key to the `UCG_AUTHKEY` field of that
  item, and it does not print it.
- `ucg_tailscale_login_server` has no default on purpose. If it is not set, `tailscale up` joins
  Tailscale SaaS. The role asserts that it is set before it runs `up`.
- The role probes for Python and does not assume that it is there. It is not documented whether
  UniFi OS ships `python3`. The playbook runs with `gather_facts: false`. The first task of the role
  is a `raw` probe, which fails with a clear message if Python is missing. If that probe ever
  fails, do not run `apt install python3`. The package goes into the overlay that a firmware
  update replaces.
- One step is manual, not Ansible. Turn off the IPS category "Peer to Peer and Dark Web"
  (Network → Security → Protection). If it is on, it can block NAT traversal to the VPS. This is
  UniFi controller configuration, outside this role.
- The zone firewall of UniFi cannot see `tailscale0`, because UniFi does not manage that interface.
  Access control for the routes lives in the Headscale policy, not in ZBF.

## Secrets

`ansible/README.md` § Secrets has the lookup form and the `op://` trap, and it wins. A working
example is the `forgejo_secret_settings` task in `ansible/roles/forgejo/tasks/main.yml`. Do not use
ansible-vault. `AGENTS.md` rule 3 (1Password only, no SOPS) wins.

## The netdata.conf chore, solved properly

TrueNAS removes `/etc/netdata/netdata.conf` on every update. If you only write the file again from
a template, the next update removes it again.

This is how netdata data reaches the cluster now. Nothing is pushed. The VMStaticScrape
`observability/netdata-atlas`
(`kube/clusters/artemis/apps/observability/victoria/agent/vmstaticscrape-atlas.yaml`) scrapes the
Prometheus endpoint of netdata, `10.10.99.100:19999/api/v1/allmetrics?format=prometheus`, as
`job=netdata, instance=atlas`. That endpoint exists only because the role rewrites the `[web]`
section of `/etc/netdata/netdata.conf` to bind `10.10.99.100:19999` (`netdata_exporter_bind`). The
role also keeps the loopback bind that the TrueNAS Reporting tab reads. A TrueNAS update removes
this section too.

`exporting.conf` does not belong to the role. The TrueNAS middleware renders it from Reporting →
Exporters (`midclt call reporting.exporters.query`). No exporter is configured there.

`roles/netdata_exporter` is the fix. The canonical configuration and a restore script live on a
dataset (`/mnt/atlas/config/netdata/`). They must not live in `/etc`, because an update replaces
`/etc`. `arensb.truenas.initscript` registers the script as POSTINIT, so the box repairs itself at
boot.

`arensb.truenas.initscript` is not idempotent on TrueNAS 25.04. A second run fails with
`Module failed: 'script_text'` on an entry that already exists. So the role first queries
`initshutdownscript.query` through `midclt`. It calls the module only when the entry is absent. The
module parameters also differ from what the docs suggest. It takes `cmd`, `name`, `when`, `state`
and `timeout`. It has no `type` or `enabled`.

## Apply by hand, never from CI

Ansible pushes changes, and it is not transactional. A half-applied run against the only hypervisor
in the house leaves it in an unknown state. No reconcile loop exists to repair it. Flux can apply
all the time because Kubernetes repairs itself. Bare metal does not. An unattended run after a
Renovate bump can reboot the box that holds the ZFS pools.

Always run `mise run //ansible:check <playbook>` first. Modules without check-mode support skip, or
they report wrong results. So a clean check run is a strong sign, but it is not proof.

Nothing runs Ansible in CI. Run the lint and the syntax check by hand, with
`mise run //ansible:lint` and `mise run //ansible:syntax-check`. A human applies from the laptop.

## Traps

- A run through the `!` prefix of Claude Code can half-apply and then report failure. Ansible
  refuses non-blocking stdio (`ERROR: Ansible requires blocking IO on stdin/stdout/stderr`). But
  that guard lives in the display layer, so it can fire _after_ tasks already changed the host.
  The play stopped, so its handlers never ran, and nothing restarts the service. The next run finds
  the configuration already correct, so it has nothing to notify either.

    Treat that error as an unknown partial apply, never as a no-op. Run again. Then make sure that
    the service actually restarted. Do not trust the recap. If you redirect the output to a file
    (`> out 2>&1`), the handles are blocking and the error does not occur. A normal terminal tab
    does not have this problem.

- TrueNAS keeps the SSH keys of root in its middleware, not in `authorized_keys`. An update removes
  a key that you write to the file. `roles/offsite_backup` adds its key through `midclt user.update`
  (`files/authorize-key.py`, delegated to atlas). The key is behind `command="rrsync …",restrict`,
  so it can write only under `/mnt/atlas/backups/pantheon`.
- Do not create Proxmox guests with Ansible. Tofu owns guest creation, and Ansible configures what
  is inside the guests. Two creators always cause drift.
- LXC containers have no cloud-init, so they need `ansible_user: root`. VMs use a normal user. The
  inventory differs on that line. `inventory/hosts.yml` already has this for the Forgejo container.
- ZFS: set dataset properties. Never create or destroy pools. Pool operations happen once, and they
  can need a reboot. Write them as a check-and-assert, not as enforced state.
- Run `ansible` directly. You do not need `mise exec`. The shims directory is on PATH through
  `~/.zshenv`, so any tool that you add to `.mise/config.toml` resolves automatically.
- `.mise/config.toml` sets `ANSIBLE_CONFIG` and the related variables as absolute paths. Without
  them, `ansible` run from the repo root silently uses `/etc/ansible/ansible.cfg`. You then get the
  wrong inventory, the wrong roles path, and no error. The variables are absolute
  (`{{config_root}}/...`), so they work from any directory. The relative paths inside
  `ansible/ansible.cfg` are only a fallback for someone who already ran `cd` into `ansible/`.
- If `ansible` refuses to start with a locale error, read `tooling.md` § mise. It wins.

## Formatting

Ansible YAML goes through the same `oxfmt` pre-commit hook as every other YAML file in the repo.
The team tested this. `ansible-lint` at the `production` profile passes on the output of oxfmt.
oxfmt changes one thing: it splits long inline flow collections across multiple lines. This
applies to both lists (`[a, b, c, ...]`) and mappings (`{k: v, k: v}`).

Use block form, which is normal Ansible style anyway. oxfmt and `ansible-lint` do not agree on how
to indent a split flow collection. So anything that oxfmt splits fails `yaml[indentation]` on the
next lint. oxfmt runs as a pre-commit hook, so that failure comes _after_ a clean pre-commit lint
run. You see it only if you lint the committed state again.

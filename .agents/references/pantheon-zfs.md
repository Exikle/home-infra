# Reference: pantheon ZFS — home-infra

This file covers the bare-metal host storage on `pantheon`. pantheon is the Proxmox box that runs
the Talos worker and GPU VMs. The storage is ZFS on an LSI HBA. The file covers pools, bays, drive
intake, transport faults, and ZED alerting. None of it is Kubernetes storage, and no manifest can
reach it. For cluster storage, see `storage.md` (storage classes, NFS, PVC lifecycle) and
`kopiur.md` (backups).

The two areas touch in one place: replica placement. `pantheon` is one machine with three
hostnames. This is the failure-domain trap. Replicated storage that spreads copies across
`talos-w-01`, `talos-w-02` and `talos-gpu-01` puts all of them on one physical host. A pantheon
outage then takes every replica at once. This applies to miroir. The topology causes it, not the
storage layer.

## pantheon (Proxmox host) — ZFS pools

The host is an HPE ML150 Gen9 with 8 SFF bays on an LSI SAS2116 HBA (IT mode, 16 ports). The OS
SSD is on the onboard Intel C610 AHCI controller. It does not use a hot-swap bay.

| Pool       | Layout                   | Usable   | Holds                            |
| ---------- | ------------------------ | -------- | -------------------------------- |
| `vmpool`   | 2× mirror, 600GB 10K SAS | 1.09 TiB | Talos worker zvols + efidisks    |
| `bulkpool` | RAIDZ1, 3× 2TB 7.2K SATA | 3.52 TiB | vzdump backups (`recordsize=1M`) |

Both pools use `ashift=12`, `compression=lz4`, `atime=off`, and WWN paths from
`/dev/disk/by-id`. Never use `sdX` names. They change order across reboots and rescans.

### Chassis bay ↔ HBA bay mapping

The two SFF-8087 connectors of the backplane are cabled in swapped order, so the numbers do not
line up. `bay_identifier` (from `/sys/class/sas_device/end_device-*/`) is the only reliable
physical identifier. SCSI target IDs and `sdX` names have no meaning here. The `sdX` names change
whenever a drive moves.

| Chassis bay | 1   | 2   | 3   | 4   | 5   | 6   | 7   | 8   |
| ----------- | --- | --- | --- | --- | --- | --- | --- | --- |
| HBA bay     | 12  | 13  | 14  | 15  | 8   | 9   | 10  | 11  |

To read the bay of a drive, run:

```sh
p=$(readlink -f /sys/block/sdX/device)
cat /sys/class/sas_device/$(echo $p | grep -oE "end_device-[0-9:]+")/bay_identifier
```

Chassis bay 1 is suspect. It is empty or blanked (2026-08-04). Two different drives in it had
transport errors:

- A NetApp X422 was ejected from `vmpool` twice with `DID_SOFT_ERROR` on large writes.
- Its HP replacement got +2,666 non-medium errors during one resilver. The other three pool drives
  got zero. When that HP drive moved to chassis bay 6, the rate fell from about 68/min to about
  0.4/min.

Test bay 1 again before you trust it.

### Migrating VM storage — mirror live, never drain

`qm move-disk <vmid> <disk> <target> --delete 1` on a running VM does a QEMU drive-mirror. It
causes no downtime, no pod eviction, and no volume detach. Use it for a disk move, not cordon and
drain. A drain evicts every pod on the VM, and the disk move does not need that.

Two limits apply:

- You cannot move `efidisk0` live. QEMU attaches it as pflash, not as a block device, so QEMU
  cannot mirror it. The VM must be fully stopped. A guest reboot, such as the reboot of a tuppr
  upgrade, does not help. The QEMU process stays up, so the pflash disk stays attached. Plan a
  short outage of that node with the user: drain the node, shut the VM down
  (`qm shutdown <vmid>`), move the disk, then start the VM.
- Move one disk at a time, not in parallel. The source pool is the bottleneck. Parallel mirrors
  turn one sequential stream into N streams that seek against each other. They also starve the
  VMs that still run from the pool.

### Used-drive intake checklist

The failure rate of used enterprise drives is high. On 2026-08-04, 1 of 5 600GB drives and 1 of
4 2TB drives were dead on arrival. Test every drive before it goes into a pool:

1. Run `smartctl -a`. The grown defect list is the important number. Also read the
   `SMART Health Status` of the drive. It reports a predicted failure before ZFS sees a problem.
2. Make sure that the logical block size is 512. Drives from arrays (NetApp/EMC) often have
   520-byte or 528-byte blocks. Linux cannot use them without a low-level reformat.
3. Run `smartctl -t long`. Then read the grown defects again. A static count is fine. A growing
   count is not.
4. Wipe old array metadata. Drives that carried LVM (old Ceph OSDs, for example) have LVM2
   members that activate automatically. They make `zpool attach` fail with "is in use and
   contains a LVM2_member filesystem". Before you wipe, make sure that the tags are foreign:
   `lvs -o lv_tags`, then `vgchange -an <vg>; wipefs -a /dev/sdX`.

### Identifying a physical drive — no LEDs on this chassis

This chassis has no SES enclosure. So it has no locate LED and no slot mapping in sysfs. SCSI
target IDs do not match bay numbers. Two methods work:

- Make real host I/O (`dd if=/dev/sdX of=/dev/null`) and look for activity.
- Pull the drive and find which serial left the bus. This is safe for a drive that is not in a
  pool, and for a redundant member.

An extended background self-test makes no bus traffic, so it lights no activity LED. During a
test, do not use "which drive is idle or blinking" to find a drive.

### `DID_SOFT_ERROR` — transport faults look like drive faults

ZFS can eject a drive with dozens of write errors while the SMART data of the drive stays clean:
the defect count does not change, and there are zero uncorrected errors. The sign is
`DID_SOFT_ERROR` in `dmesg` on large multi-segment writes. The HBA aborted the command, so the
drive never saw it fail. This points to a weak link (the drive interface, the caddy, or the
backplane path), not a media fault. To find which, move the drive to a different bay. If the
errors follow the drive, the drive is bad. If the errors stay, the bay is bad.

### Alerting

ZED posts to Alertmanager through `/etc/zfs/zed.d/statechange-alertmanager.sh`. That script is
symlinked for `data`/`io`/`checksum`/`scrub_finish`/`resilver_finish`. The posts go to
`https://alertmanager.dcunha.io/api/v2/alerts` over the internal gateway. Alerts carry
`job=zed, instance=pantheon`. Alertmanager routes by `severity` only. So an alert reaches
`chaski-critical` only if the zedlet also sets `severity=critical`. The zedlet is managed by hand
on the host and is not in git.

Outbound mail from pantheon is broken. Do not set anything to notify through `root` mail. That
mail goes nowhere. This is why nobody saw a faulted drive before the bridge existed.

Hot spares engage automatically on the OpenZFS that pantheon runs (`zfs version`). The
`zfs_retire` agent of ZED handles spares,
not a shell zedlet (`spare.sh` no longer exists). To add a spare, run
`zpool add vmpool spare <wwn>`.

## What is and is not backed up on this host

`vzdump` covers only LXC 105 (`forgejo`). It runs nightly at 02:00 to `bulkpool-backups`. It keeps
7 daily, 4 weekly, and 3 monthly backups. The three Talos worker VMs (101, 102, 104) are not in
any backup job, on purpose. The team rebuilds them from `kube/clusters/artemis/talos/` +
`terraform/stacks/proxmox`. They hold no data that miroir does not replicate or that kopiur
cannot restore. If that stops being true, add them with
`pvesh set /cluster/backup/forgejo-daily --vmid 101,102,104,105` (ZFS snapshot mode, no
downtime).

`pve-etc-backup.timer` makes a daily tar of the host configuration in
`/bulkpool/backups/host-etc/`. The tar holds:

- `/etc`
- A plain-file copy of the pmxcfs `/etc/pve` view
- The guest configurations
- The PVE root CA key
- A `pvesh` resource dump
- The pool and disk inventories

It keeps 30 copies. If it fails, it posts to Alertmanager through `alertmanager-notify@.service`.
This protects against the loss of the single boot SSD, which is the realistic failure.

Before the Sunday Forgejo self-update, `roles/pve_guest_snapshots` takes an `auto_*` ZFS snapshot
of CT 105 at 02:55 UTC and keeps the newest 4 (`ansible.md` § The host updates itself — do not let
the role fight it). These snapshots live on `vmpool`. They are not off-host.

Off-host since 2026-10-10: `offsite-backup.timer` (`roles/offsite_backup`) copies all of
`/bulkpool/backups` to `atlas:/mnt/atlas/backups/pantheon` nightly at 05:30, after the 02:00
vzdump. The 30-day snapshot task of atlas on `atlas/backups` keeps the history.

# Reference: Hardware — home-infra

This file is the physical inventory and the traps that come with it. Read it before you size a
workload, pin it to a node, or buy a part. Also read it before you explain a latency symptom that
appears to come from software.

Node names and roles are live facts. `kubectl get nodes -o wide` and `talosctl get members` are
the ground truth. This file records what those commands cannot tell you: which part is in which
box, and which part caused problems.

## Control Planes (metal)

3× Lenovo M710q: `talos-cp-01/02/03`. Each has a 256GB NVMe (Samsung MZVLW256HEHP) for cluster
storage and sits on VLAN 1099 (LAB). The IPs come from DHCP reservations on the UCG, not from
static configuration.

The three boot SSDs are not the same, and the difference is important. cp-02/03 have an 860 EVO
500GB (TLC). cp-01 has a Dell/Intel D3-S4610 240GB (`SSDSC2KG240G8R`, 3D TLC with power-loss
protection). It went in on 2026-09-19.

It replaced an 860 QVO 1TB (QLC). The worst case for that drive was the access pattern of etcd:
sustained small sync writes. The average device write latency of `sda` was 61.3ms on cp-01,
against 1.9ms on cp-02/03. So the apiserver of cp-01 was about 7× slower on pod reads. This caused
the cluster-wide Multus sandbox failures in #1956 / #2088. The QVO was not failing. It had no ATA
errors, it was 8% full, and it was stable for months. It was the wrong class of drive for etcd,
and no tuning made a difference. An etcd boot disk must be TLC with power-loss protection, never QLC.

The power-loss-protection capacitors of the S4610 are what fix the problem. The drive
acknowledges an fsync from its DRAM and does not wait for the NAND.

cp-01 has the least disk headroom in the fleet: 240GB, against 500GB on cp-02/03. Kubelet image
GC (85% threshold) keeps the usage under control, and images are most of the usage. You do not
have to do anything. But if a disk-pressure eviction occurs, examine this node first.

The full model strings come from the `by-id` symlink (`talosctl get disk sda -o yaml`). The
`model:` field truncates at 16 bytes to `Samsung SSD 860`, so it hides the EVO/QVO difference
fully. This is why nobody saw the mismatch for months.

## Workers (Proxmox VMs on `pantheon`)

- `talos-w-01`, `talos-w-02`: 32GB RAM, 6 vCPU (NUMA-pinned), 128GB disk
- `talos-gpu-01`: 32GB RAM, 6 vCPU, ASRock Arc A380 passthrough (6GB)

## Workers (metal)

ymir: Gigabyte C246N-WU2 | Xeon E-2124G (4C/4T) | 16GB, 2 slots free | 128GB SATA M.2.

- It has a 1U chassis. A discrete card needs a riser and must lie flat. Before you order one,
  make sure that the cooling clearance is sufficient and that an 8-pin PCIe connector is
  available.
- The UHD Graphics P630 iGPU decodes HEVC 10-bit and VP9. It is a better transcoder than the
  HD 530s of the M710q.
- `eno1` (`d8:5e:d3:00:ea:81`) is the cabled NIC. `enp3s0` (`…:82`) is not used.
- BIOS F1: keep the defaults. `Initial Display Output → IGFX` and `CSM → Disabled` each stop the
  video output on their own.

## Proxmox host (`pantheon`)

HPE ML150 G9 | 2× Xeon E5-2620 v3 (12 cores / 24 threads total).

The drives sit on an LSI SAS2116 HBA in IT mode, not on a Smart Array card. So there is no
`ssacli` and no RAID mode to change. For the pool layout and the drive-bay mapping, see
`pantheon-zfs.md`. For the host NIC and the bridge layout, see `pantheon-networking.md`.

## Storage

- TrueNAS (`atlas`, 10.10.99.100): 3× RAIDZ2 (run `zpool list` on the box for capacity), NFS at
  `/mnt/atlas/media`.
- miroir (`miroir-system`): replicated block storage on the M710q NVMe. StorageClasses `miroir`
  (default, 2 replicas) and `miroir-local`. App configuration and databases only, never media.

Rook-Ceph is gone. `AGENTS.md` § What was deliberately removed is the home for that, and it wins.

For everything else about volumes (the NFS media mount, orphaned PVCs), see `storage.md`.

## Known hardware and ops issues

Eaton UPS: the batteries are dead. It gives no real protection. Treat the cluster as a cluster
with no power backup.

TrueNAS netdata scrape: `ansible.md` § The netdata.conf chore, solved properly.

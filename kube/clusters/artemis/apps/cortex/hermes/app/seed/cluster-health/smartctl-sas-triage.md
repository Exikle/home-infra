# SmartScsiGrownDefectsIncreasing (pantheon SAS drives)

This alert is not auto-fixable. It is a media-wear signal on the Proxmox host `pantheon`, which is
outside the cluster.

## Verify

- Read `smartctl_scsi_grown_defect_list{instance="pantheon"}` per device. Four SAS devices report
  this metric. NVMe devices do not. The device letters change when the host reboots or the HBA
  changes, so track each drive by its count, not by its letter.
- Read `smartctl_device_smart_status{instance="pantheon"}`. All 8 series must be 1 (PASSED). A 0
  is a real failure. Escalate it.
- The alert fires when a count grows within a rolling 24 h window
  (`delta(smartctl_scsi_grown_defect_list[1d]) > 0`). It cleared on 2026-10-17 after about 6 days
  with no further growth.

## State at 2026-10-17

One drive plateaued at 8. Its fire cycles closed at 5 on 2026-09-25, 6 on 2026-10-07, 7 on
2026-10-10 and 8 on 2026-10-17. A second drive stayed at 10 from 2026-09-08. The other two drives
stayed at 0. All devices passed SMART. RESOLVED 2026-10-17 12:02Z. This skill had nothing to do.

At that time the drives at 8 and 10 were `sdh` and `sdf`. On 2026-11-18 the devices were `sdb`=0,
`sdc`=8, `sdd`=0 and `sde`=10.

If a new fire cycle starts, a drive grew again. Report the device, its new count and the number of
cycles so far. The pattern suggests slow wear on the shelf, so tell the operator to watch it.

Older detail: `/opt/data/workspace/cluster-health/archive/smartctl-sas-triage.full.md`.

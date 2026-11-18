# Miroir (DRBD mirror) alert triage

None of these classes is auto-fixable. Each fix changes a PVC, a PV or a node, which is operator
work. Report all of them as `attention` on the `warning` route ("needs human attention").

## MiroirVolumeOutOfSync (persistent over 1 h)

The alert description is the diagnosis. A peer is out of sync for over an hour, and the auto-cycle
of the miroir agent did not drain it. There are three branches:

1. A down peer collects exposure. Make sure that all `talos-cp-*` nodes are Ready
   (`k8s_resources_list` v1 Node). If they are, this branch is not the cause.
2. A resync stalled. `miroir_volume_out_of_sync_bytes` is not zero, and
   `miroir_volume_resync_ratio` is between 0 and 0.99.
3. `drbdadm verify` found blocks that the auto-resync cannot repair. The ratio is 1, and the
   out-of-sync bytes stay above zero. The operator must run a manual disconnect/connect cycle. The
   alert description points to the miroir troubleshooting guide for it.

Also read the pool usage: `miroir_pool_allocated_bytes / miroir_pool_capacity_bytes * 100` per
`{pool, node}`. Above about 85%, writes can fail and look like a stalled resync. List the volumes
by `miroir_volume_out_of_sync_bytes`, largest first. The operator must start with the largest.
Small ones (under 10 MiB) on several replicas are usually side effects of the same verify sweep.

## MiroirPoolUsageHigh (client pool above 80%)

This alert recurs on the client pools of talos-w-01, talos-w-02 and talos-gpu-01. Each fire cycle
lasted about 1 to 35 hours. Then it cleared without help as volumes moved or were cleaned up. So a
single occurrence is usually not an incident. Report the live percentage and how long the cycle
runs. Do not report the alert annotation, because it can come from a short burst. Operator fix:
move volumes off the pool, or expand the backing vdev. Last resolved 2026-10-07 16:02Z
(talos-w-01).

## MiroirVolumeNotUpToDate, MiroirVolumeQuorumLost, MiroirVolumeDisconnected

These alerts come with the ones above and have the same root cause. The QuorumLost and
Disconnected set of 2026-09-09/10 (three `*-src` snapshot-source volumes on talos-cp-02) cleared
without help.

## Other Miroir alerts

Any other `Miroir*` alert (for example SplitBrain, DiskFailed, ReadOnly, AgentDown) is not
auto-fixable either. Report it as `attention`, and quote its description. The description names
the operator fix.

## Network note

The nvme-pool volumes sit on talos-cp-01/02/03 (10.10.99.101-103). If a Miroir alert shows an IP
that is not in the Network map in `SKILL.md`, examine it before you call it stale.

## Recurrence log (open cases only)

Format and rules are in `SKILL.md` § Documented cases. No open Miroir case at 2026-10-21. Full history (49 entries, 2026-09-07 to 2026-10-07) is archived in `/opt/data/workspace/cluster-health/archive/miroir-triage.full.md`.

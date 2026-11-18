# KubePersistentVolumeFillingUp: apoci PVC (fediverse)

Seen once, 2026-09-28 (critical, from 03:42 EDT). This case is not auto-fixable. The skill must
not touch PVCs.

- The `apoci` PVC is in `fediverse`. It uses the `miroir` class, 15Gi, RWO. The pod is healthy,
  with no restarts.
- The alert fires only when two things are true for 1h. Less than 15% of the volume is free now
  (`available/capacity < 0.15`). Also, the 6 h trend reaches zero within 4 days
  (`predict_linear(kubelet_volume_stats_available_bytes[6h], 4 * 24 * 3600) < 0`).
- The alert text "0.08% free" is the free fraction, 0.08, printed with a `%` sign. It means 8%
  free. For the real figure, read `kubelet_volume_stats_used_bytes` and
  `kubelet_volume_stats_available_bytes`. On 2026-09-28 they gave 13.47 GiB used and 1.19 GiB
  free (8%). The usage was flat for the last 1h45m, after a burst of about 500 MB.
- If used bytes keep going up between runs, the disk can fill within about an hour. Say so in
  `items`.
- Operator actions: grow the PVC `spec.resources.requests.storage` (the miroir class allows
  expansion). Or tighten the registry retention, `gc.retention` in
  `kube/clusters/artemis/apps/fediverse/apoci/app/resources/config.yaml`. The repo skill
  `.agents/skills/apoci-federation/SKILL.md` § Garbage Collection & Retention explains it.

At 2026-10-21 the PVC is still 15Gi and the alert is not firing. No recurrence log is kept for it.

# Case index (read this on every run; one row per case, one line each)

## Open cases

This table holds the cases that fire now, or that you logged recently and did not yet mark
RESOLVED. If a case in this table is absent from the firing set, follow the "Open-case row is no
longer in the findings" rule in `SKILL.md` § Documented cases. When you log the first recurrence
of a case, add a row. When you write its RESOLVED entry, move the row to the table below.

| Alert / target       | First seen | Detail |
| -------------------- | ---------- | ------ |
| (none at 2026-10-21) |            |        |

## Resolved cases

If a case in this table is absent from the firing set, run its verify query once and put one line
in `items`. Do not append to any log. If the alert fires again, move the row back to Open cases
and log a recurrence in its detail file. The pantheon device letters change when the host
reboots, so the smartctl row checks the counts, not the letters.

| Alert / target                                                   | Resolved                | Verify (VictoriaMetrics, port 8428)                                                            | Detail                                                         |
| ---------------------------------------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| TargetDown `smartctl-exporter` (static `instance=pantheon`)      | 2026-08-15              | `up{job="smartctl-exporter"}` 8/8 = 1                                                          | targetdown-triage.md                                           |
| TargetDown `kube-apiserver` (talos-cp-02 `/metrics` over 16 MiB) | 2026-09-23              | `up{job="kube-apiserver"}` 3/3 = 1                                                             | targetdown-triage.md                                           |
| EtcdDatabaseHighFragmentationRatio (cp-01/02/03)                 | 2026-09-23              | alert absent; ratio `etcd_mvcc_db_total_size_in_use_in_bytes/etcd_mvcc_db_total_size_in_bytes` | etcd-triage.md                                                 |
| MiroirPoolUsageHigh (client pools; recurs, self-clears)          | 2026-10-07 (talos-w-01) | alert absent; pool % = `miroir_pool_allocated_bytes/miroir_pool_capacity_bytes*100` below 80   | miroir-triage.md                                               |
| PocketIDOIDCClientPKCESupported (any OIDC client)                | 2026-10-16              | alert absent                                                                                   | pocket-id-operator-triage.md                                   |
| SmartScsiGrownDefectsIncreasing (pantheon SAS; 4 fire cycles)    | 2026-10-17              | alert absent; `smartctl_scsi_grown_defect_list{instance="pantheon"}` values still 0, 0, 8, 10  | smartctl-sas-triage.md                                         |
| KubePersistentVolumeFillingUp `fediverse/apoci` (seen once)      | 2026-09-28              | alert absent; `kubelet_volume_stats_available_bytes{persistentvolumeclaim="apoci"}` above 15%  | grow the PVC, or tighten `gc.retention` in apoci `config.yaml` |

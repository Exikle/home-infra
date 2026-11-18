---
name: restore-drill
description: Check whether backups are in a state that could actually be restored — CNPG backup and WAL archiving status, and kopiur snapshot freshness. Use for "backup health check", "CNPG backup status", "restore drill", "are backups working", or "WAL archiving". It reports. It does not restore. To actually restore, use `kopiur-restore`. For overall cluster health rather than backups, use `cluster-status`. Covers Artemis and Frostlink.
compatibility: Read-only. It uses plain `kubectl get` against the CNPG and kopiur CRDs, and needs no plugin. It does not perform a test restore, because CNPG recovery overwrites the cluster. Do that only on an explicit request.
---

# Skill: Restore Drill

This skill is a read-only check. It makes sure that CNPG database backups exist and that a
recovery path is viable. It does not run a restore.

Both clusters back up Postgres with the barman-cloud plugin to R2. The plugin keeps its backup
status on the `ObjectStore/r2-store` in `database`, not on the `Cluster`. On Frostlink, read
`frostlink.md` in this folder first. Frostlink has no separate WAL volume, and it adds a
deep-verify check. The steps below are for Artemis. Every `kubectl` command pins
`--context artemis`.

## Step 1: Confirm Backups Exist

```bash
kubectl get backups.postgresql.cnpg.io -n database --sort-by=.metadata.creationTimestamp --context artemis
kubectl get scheduledbackup -n database --context artemis
```

A healthy backup list ends in recent `completed` entries. If the list is empty, or all entries are
`failed`, escalate. There is no recovery path.

## Step 2: Check Cluster Status

```bash
kubectl describe cluster postgres -n database --context artemis   # the only CNPG cluster since 2026-09-01
kubectl -n database get objectstore r2-store -o jsonpath='{.status.serverRecoveryWindow.postgres}' --context artemis
```

In the `describe` output, look for these items:

1. The condition `ContinuousArchiving` has `Status: True` and `Reason: ContinuousArchivingSuccess`.
   This means that WAL streams to backup storage.
2. The condition `LastBackupSucceeded` has `Status: True`.
3. `Phase: Cluster in healthy state`.

In the `ObjectStore` output, `lastSuccessfulBackupTime` must be recent. The `lastSuccessfulBackup`
and `firstRecoverabilityPoint` fields on the `Cluster` stay empty with the plugin. Do not read them.

## Step 3: Verify WAL Archiving

Select the primary by label. The primary can move to another instance, and a replica errors on
`pg_current_wal_lsn()`:

```bash
kubectl -n database get pods -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary --context artemis
kubectl exec -n database <primary-pod> --context artemis -- \
  psql -U postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"
```

The direct signal is the count of ready segments. If the count is above zero, the archive stalled
and WAL piles up:

```bash
kubectl exec -n database <primary-pod> --context artemis -- \
  psql -U postgres -tAc "SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready';"
kubectl exec -n database <primary-pod> --context artemis -- df -h /var/lib/postgresql/wal
```

WAL has its own volume (`spec.walStorage.size` on the `Cluster`). A stall fills that volume, not
the data volume. `CNPGWalArchiveBacklog` / `CNPGDataVolumeFillingUp` page before it matters. Do
not alert on `seconds_since_last_archival`. An idle database skips the WAL switch that
`archive_timeout` forces. So that metric climbs past the timeout although nothing is wrong.

Then make sure that the barman object store is reachable:

```bash
kubectl -n database get objectstore r2-store -o yaml --context artemis | grep -A5 status
kubectl -n cnpg-system logs deploy/plugin-barman-cloud --tail=50 --context artemis
```

A credential problem shows here long before it shows as a missing backup.

## Step 4: Verify PVC Snapshots (kopiur)

kopiur backs up app PVCs. barman covers the CNPG data.

```bash
kubectl get snapshotpolicy -A --context artemis
kubectl get snapshot -n <namespace> --sort-by=.metadata.creationTimestamp --context artemis
kubectl describe snapshotpolicy <app> -n <namespace> --context artemis
```

Read the `SnapshotPolicy` status for a recent successful snapshot. Make sure that the newest
`Snapshot` for the app completed. A policy with no recent Snapshot is the failure to catch.

## Step 5: Confirm PITR Recoverability

PITR (point-in-time recovery) restores the database to any moment inside the recovery window.

```bash
kubectl -n database get objectstore r2-store -o jsonpath='retention={.spec.retentionPolicy}{"\n"}{.status.serverRecoveryWindow.postgres}{"\n"}' --context artemis
```

The PITR window runs from `firstRecoverabilityPoint` to now. The `retentionPolicy` of the
`ObjectStore` limits it.

## Output

Report the findings in this format:

```
## Restore Drill — <app> in <namespace> — <date>

Backups:       ✅ <n> completed backups; oldest <date>
WAL archiving: ✅ ContinuousArchiving True (ContinuousArchivingSuccess)
WAL storage:   ✅ <percent> used (<used> / <walStorage size>)
kopiur:        ✅ Last snapshot <age> ago
PITR window:   ✅ <firstRecoverabilityPoint> → now (retention <retentionPolicy>)

Recovery path: VIABLE. RPO is at most <archive_timeout> (WAL switch interval).
```

RPO (recovery point objective) is the most data that a restore can lose. Read `<archive_timeout>`
with `kubectl -n database get cluster postgres -o jsonpath='{.spec.postgresql.parameters.archive_timeout}' --context artemis`.

If you find issues, report them like this:

```
WAL archiving: ❌ Not configured — only full backup recovery possible, no PITR
Backups:       ⚠️  Last completed backup 8 days ago — exceeds expected cadence
```

## Notes

- This skill is read-only. Do not run a test restore unless the user asks for one. CNPG recovery
  overwrites the cluster.
- If backups are missing, read the `scheduledbackup` resource. Make sure that the ExternalSecret
  synced the secret for the backup storage.

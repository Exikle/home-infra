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
deep-verify check. The steps below are for Artemis.

## Step 1: Confirm Backups Exist

```bash
kubectl get backups.postgresql.cnpg.io -n <namespace>
kubectl get scheduledbackup -n <namespace>
```

A healthy backup list shows recent `completed` entries. If the list is empty, or all entries are
`failed`, escalate. There is no recovery path.

## Step 2: Check Cluster Status

```bash
kubectl describe cluster postgres -n database   # the only CNPG cluster since 2026-09-01
kubectl -n database get objectstore r2-store -o jsonpath='{.status.serverRecoveryWindow.postgres}'
```

In the `describe` output, look for these items:

1. The condition `ContinuousArchiving` has `Status: True` and `Reason: ContinuousArchivingSuccess`.
   This means that WAL streams to backup storage.
2. The condition `LastBackupSucceeded` has `Status: True`.
3. `Phase: Cluster in healthy state`.

In the `ObjectStore` output, `lastSuccessfulBackupTime` must be recent. The `lastSuccessfulBackup`
and `firstRecoverabilityPoint` fields on the `Cluster` stay empty with the plugin. Do not read them.

## Step 3: Verify WAL Archiving

```bash
kubectl exec -n database postgres-1 -- \
  psql -U postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"
```

The direct signal is the count of ready segments. If the count is above zero, the archive stalled
and WAL piles up:

```bash
kubectl exec -n database postgres-1 -- \
  psql -U postgres -tAc "SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready';"
kubectl exec -n database postgres-1 -- df -h /var/lib/postgresql/wal
```

Since 2026-09-01, WAL has its own 8Gi volume. A stall fills that volume, not the data volume.
`CNPGWalArchiveBacklog` / `CNPGDataVolumeFillingUp` page before it matters. Do not alert on
`seconds_since_last_archival`. An idle database skips the WAL switch that `archive_timeout`
forces. So that metric climbs past the timeout although nothing is wrong.

## Step 4: Verify PVC Snapshots (kopiur)

If kopiur is configured for the CNPG PVC, run these commands:

```bash
kubectl get snapshot,snapshotpolicy,snapshotschedule -n <namespace>
kubectl describe snapshotpolicy <app> -n <namespace>
```

The VolSync `ReplicationSource`/`ReplicationDestination` objects are gone. The repo removed
VolSync on 2026-08-01, and those CRDs do not exist in this cluster. The kopiur equivalents are
`Snapshot` (one backup run), `SnapshotPolicy` (what and how, per app), `SnapshotSchedule` (when)
and `Restore`. The `components/kopiur/backup` component makes the policy, the schedule, the PVC
and the `Restore` from `${APP}`.

Read the `SnapshotPolicy` status for a recent successful snapshot. Make sure that the newest
`Snapshot` for the app completed. A policy with no recent Snapshot is the failure to catch.

## Step 5: Confirm PITR Recoverability

PITR (point-in-time recovery) restores the database to any moment inside the recovery window.

```bash
kubectl -n database get objectstore r2-store -o jsonpath='retention={.spec.retentionPolicy}{"\n"}{.status.serverRecoveryWindow.postgres}{"\n"}'
kubectl get backups.postgresql.cnpg.io -n database -o json | \
  python3 -c "import sys,json; bs=[b for b in json.load(sys.stdin)['items'] if b['status'].get('phase')=='completed']; print(f'{len(bs)} completed backups; oldest: {min(b[\"status\"][\"startedAt\"] for b in bs)}') if bs else print('NO COMPLETED BACKUPS')"
```

The PITR window runs from `firstRecoverabilityPoint` to now. The `retentionPolicy` of the
`ObjectStore` limits it, however many base backups the second command counts.

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
with `kubectl -n database get cluster postgres -o jsonpath='{.spec.postgresql.parameters.archive_timeout}'`.

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

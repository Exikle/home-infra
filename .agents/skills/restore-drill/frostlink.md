# Restore Drill on Frostlink

This drill is read-only. It runs no restore. Every `kubectl` pins `--context frostlink`, because
the MCP k8s tools act on Artemis. Frostlink has one node, and the Postgres replicas live on it
too. So a replica is not a backup. You must check two paths: CNPG with barman to R2 for the
database, and Kopiur snapshots to R2 for PVCs.

| Path     | Resources                                                                                                                                        | Destination                                             |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| Database | `Cluster/postgres` + `ScheduledBackup/postgres-backup` in `database`, via the `barman-cloud.cloudnative-pg.io` plugin and `ObjectStore/r2-store` | `s3://frostlink-kopiur/barman/`, `retentionPolicy: 14d` |
| PVCs     | Kopiur `SnapshotPolicy`/`SnapshotSchedule`/`Restore` from `components/kopiur`                                                                    | `ClusterRepository/r2` (Cloudflare R2)                  |

Apps with Kopiur: `grep -rl components/kopiur kube/clusters/frostlink/apps/`.

## Step 1: CNPG backups exist and are recent

```bash
kubectl -n database get scheduledbackup --context frostlink
kubectl -n database get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp --context frostlink
```

`ScheduledBackup/postgres-backup` runs at 00:30 daily. A healthy list ends in recent `completed`
entries. If the list is empty, or all entries are `failed`, there is no recovery path. Escalate
at once.

## Step 2: Cluster health and WAL archiving

```bash
kubectl -n database get cluster postgres --context frostlink
kubectl -n database describe cluster postgres --context frostlink | grep -iA2 'archiv\|last.*backup\|phase'
kubectl -n database get objectstore r2-store -o jsonpath='{.status.serverRecoveryWindow.postgres}' --context frostlink
```

Look for these items:

1. The condition `ContinuousArchiving` has `Status: True` and `Reason: ContinuousArchivingSuccess`.
2. The condition `LastBackupSucceeded` has `Status: True`.
3. `Phase: Cluster in healthy state`.
4. A recent `lastSuccessfulBackupTime` in the `ObjectStore` output. The barman plugin writes it
   there. The `lastSuccessfulBackup` field on the `Cluster` stays empty.

Make sure that WAL moves. Select the primary by label, because the primary can move to the other
instance and a replica errors on `pg_current_wal_lsn()`:

```bash
kubectl -n database get pods -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary --context frostlink
kubectl -n database exec <primary-pod> --context frostlink -- psql -U postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"
```

There is no separate `walStorage` PVC. Each instance has one `storage` volume on `openebs-zfs`. If
archiving breaks, WAL piles up there and fills the data volume. Read its usage:

```bash
kubectl -n database exec <primary-pod> --context frostlink -- df -h /var/lib/postgresql/data
```

## Step 3: The barman object store is reachable

```bash
kubectl -n database get objectstore r2-store -o yaml --context frostlink | grep -A5 status
kubectl -n cnpg-system logs deploy/plugin-barman-cloud --tail=50 --context frostlink
```

A credential problem shows here long before it shows as a missing backup.

## Step 4: Kopiur snapshot freshness

```bash
kubectl get snapshotpolicy -A --context frostlink
kubectl get snapshot -A --sort-by=.metadata.creationTimestamp --context frostlink | tail -20
kubectl -n kopiur-system get clusterrepository r2 -o yaml --context frostlink | grep -A10 status
```

The cadence differs per app on purpose. Most are hourly, `vm-single` is daily (`H 3 * * *`) and
`apoci` is six-hourly. Judge staleness against the `KOPIUR_SCHEDULE` in the `ks.yaml` of the app,
not against one global expectation. `KopiurPolicyBackupStale` in
`kube/clusters/frostlink/apps/observability/vm-alert/app/vmrule.yaml` encodes the same
thresholds per policy.

## Step 5: The only check that proves the data comes back

The deep verify of Kopiur is internally a real scratch restore. It makes a scratch PVC and
removes it again, and it never touches the live volume. The weekly `quick` verification checks
blobs only. It proves nothing about recoverability.

```bash
kubectl get snapshotpolicy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,DEEP:.spec.verification.deep.schedule.cron --context frostlink
kubectl -n <ns> get snapshotpolicy <name> -o jsonpath='{.status}' --context frostlink
```

Deep verify (`components/kopiur-deep-verify`) runs monthly (`H 5 1 * *`) on `gotosocial` and
`headscale`. Read each policy that has a `DEEP` schedule. If its last deep verification is older
than about 5 weeks, or failed, say so plainly. Until it passes, the rest of the Kopiur report
rests only on what Kopiur says about itself.

## Step 6: Confirm a PITR window

PITR (point-in-time recovery) restores the database to any moment inside the recovery window.

```bash
kubectl -n database get objectstore r2-store -o jsonpath='retention={.spec.retentionPolicy}{"\n"}{.status.serverRecoveryWindow.postgres}{"\n"}' --context frostlink
kubectl -n database get backups.postgresql.cnpg.io -o json --context frostlink | python3 -c "import sys,json; bs=[b for b in json.load(sys.stdin)['items'] if b['status'].get('phase')=='completed']; print(f'{len(bs)} completed backups; oldest {min(b[\"status\"][\"startedAt\"] for b in bs)}') if bs else print('NO COMPLETED BACKUPS')"
```

The PITR window runs from `firstRecoverabilityPoint` to now. The `ObjectStore` retention is
`14d`, so the window cannot exceed that, however many base backups the second command counts.
Use the report format of SKILL.md, and add a `Deep verify` line. End with "Single node: recovery
is a restore, never a failover."

## Notes

- Do not run a test restore unless the user asks for one. CNPG recovery overwrites the cluster,
  and `mise run //kube/clusters/frostlink:restore-pvc` deletes the PVC. For a real restore, use
  `kopiur-restore`.
- If `Snapshot` objects are missing entirely, make sure that the `Restore` CR was not made before
  the first snapshot of the app. `.agents/references/openebs-zfs.md` § Restore covers the silent
  empty-restore failure that this drill must catch early.
- If you repoint a failing R2 credential at the wrong 1Password item, the credential is
  unrecoverable. Read `.agents/references/openebs-zfs.md`
  § "The R2 credential key is unrecoverable if repointed" before you touch anything in
  `kopiur-system`.

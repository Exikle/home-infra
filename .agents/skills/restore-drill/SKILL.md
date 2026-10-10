---
name: restore-drill
description: Verify Frostlink's backups are actually restorable — CNPG barman backup and WAL archiving status, Kopiur snapshot freshness, and the deep-verify scratch restore. Use for "backup health check", "CNPG backup status", "restore drill", "are backups working", "WAL archiving", or "is R2 up to date". Read-only. Scoped to the Frostlink cluster. It reports; it does not restore — that is `kopiur-restore`. For overall cluster health rather than backups, use `cluster-status`.
compatibility: Read-only. Requires the kopiur CRDs and CNPG barman objects; the deep-verify restore provisions a scratch PVC and removes it, and never touches the live volume.
---

# Skill: Restore Drill

Read-only assurance that Frostlink's two backup paths — CNPG/barman to R2 for the database, and
Kopiur snapshots to R2 for PVCs — are alive and that a recovery path exists. **Performs no
restore.** This matters more here than on a multi-node cluster: there is one node, one Postgres
instance, and nothing to fail over to.

Local `kubectl` is already scoped to Frostlink by `.mise/config.toml` — no `--context`, no
`--kubeconfig`, and do not use the k8s MCP tools (they act on Artemis).

## What exists to check

| Path     | Resources                                                                                                                              | Destination                                             |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Database | `Cluster/postgres` + `ScheduledBackup/postgres-backup` in `database`, via the `barman-cloud.cnpg.io` plugin and `ObjectStore/r2-store` | `s3://frostlink-kopiur/barman/`, `retentionPolicy: 14d` |
| PVCs     | Kopiur `SnapshotPolicy`/`SnapshotSchedule`/`Restore` from `components/kopiur`                                                          | `ClusterRepository/r2` (Cloudflare R2)                  |

Apps currently backed by Kopiur: `fediverse/gotosocial` (also `kopiur-deep-verify`),
`fediverse/apoci`, `matrix/continuwuity`, `network/headscale`, `observability/vm-single`, `towonel/towonel`. Confirm
rather than trusting this list: `grep -rl components/kopiur kubernetes/apps/`.

## Step 1 — CNPG backups exist and are recent

```bash
kubectl -n database get scheduledbackup
kubectl -n database get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp
```

`ScheduledBackup/postgres-backup` runs at 00:30 daily. A healthy list ends in recent `completed`
entries. Empty, or all `failed`, means **there is no recovery path** — escalate immediately.

## Step 2 — Cluster health and WAL archiving

```bash
kubectl -n database get cluster postgres
kubectl -n database describe cluster postgres | grep -iA2 'archiv\|last.*backup\|phase'
```

Look for `ContinuousArchiving: ContinuousArchivingSuccess`, a recent `lastSuccessfulBackup`, and
`phase: Cluster in healthy state`.

Confirm WAL is actually moving:

```bash
kubectl -n database exec postgres-1 -- psql -U postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"
```

**There is no separate `walStorage` PVC** — the cluster has a single 10Gi `storage` volume on
`openebs-zfs`. If archiving breaks, WAL accumulates there and fills the data volume, so check it:

```bash
kubectl -n database exec postgres-1 -- df -h /var/lib/postgresql/data
```

## Step 3 — The barman object store is reachable

```bash
kubectl -n database get objectstore r2-store -o yaml | grep -A5 status
kubectl -n cnpg-system logs deploy/plugin-barman-cloud --tail=50
```

A credential problem shows up here long before it shows up as a missing backup.

## Step 4 — Kopiur snapshot freshness

```bash
kubectl get snapshotpolicy -A
kubectl get snapshot -A --sort-by=.metadata.creationTimestamp | tail -20
kubectl -n kopiur-system get clusterrepository r2 -o yaml | grep -A10 status
```

Per-app cadence differs on purpose — most are hourly, `vm-single` is daily (`H 3 * * *`) and
`apoci` six-hourly. Judge staleness against the app's own `KOPIUR_SCHEDULE` in its `ks.yaml`, not
against a single global expectation. `KopiurPolicyBackupStale` in
`observability/vm-alert/app/vmrule.yaml` encodes the same per-policy thresholds.

## Step 5 — The only check that proves the data comes back

Kopiur's **deep verify** is a real scratch restore under the hood. Weekly `quick` verification is
blob-level only and proves nothing about recoverability.

```bash
kubectl -n fediverse get snapshotpolicy gotosocial -o yaml | grep -A12 verification
kubectl -n fediverse get snapshotpolicy gotosocial -o jsonpath='{.status}' | python3 -m json.tool
```

Deep verify runs monthly (`H 5 1 * *`) and is currently enabled on `gotosocial` only. If its last
deep verification is older than ~5 weeks or failed, say so plainly — the rest of the Kopiur
reporting is self-attested until this passes.

## Step 6 — Confirm a PITR window

```bash
kubectl -n database get backups.postgresql.cnpg.io -o json | python3 -c "import sys,json; bs=[b for b in json.load(sys.stdin)['items'] if b['status'].get('phase')=='completed']; print(f'{len(bs)} completed backups; oldest {min(b[\"status\"][\"startedAt\"] for b in bs)}') if bs else print('NO COMPLETED BACKUPS')"
```

The `ObjectStore` retention is `14d`, so the PITR window cannot exceed that regardless of how many
base backups are listed.

## Output

```
## Restore Drill — Frostlink — <date>

CNPG backups:   ✅ 12 completed; oldest 2026-08-07
WAL archiving:  ✅ ContinuousArchivingSuccess
Data volume:    ✅ 31% used (3.1Gi / 10Gi)
Kopiur:         ✅ 6 policies, newest snapshot 42m ago; vm-single 9h (daily, expected)
Deep verify:    ⚠️  gotosocial last deep verify 38 days ago
PITR window:    ✅ 14d (ObjectStore retentionPolicy)

Recovery path: VIABLE. Single node — recovery is a restore, never a failover.
```

## Notes

- **Read-only.** Do NOT run a test restore unless explicitly asked — CNPG recovery overwrites the
  cluster, and `just kube restore` deletes the PVC. For an actual restore use the
  `kopiur-restore` skill.
- If `Snapshot` objects are missing entirely, check that the `Restore` CR was not created before
  the app's first snapshot — see `.agents/references/storage.md` § Restore for the silent
  empty-restore failure that this drill is meant to catch early.
- A failing R2 credential is unrecoverable if repointed at the wrong 1Password item — read
  `.agents/references/storage.md` § "The R2 credential key is unrecoverable if repointed" before
  touching anything in `kopiur-system`.

# EtcdDatabaseHighFragmentationRatio triage

## Key insight: the ratio denominator

The live rule is
`(1 - etcd_mvcc_db_total_size_in_use_in_bytes / etcd_mvcc_db_total_size_in_bytes) > 0.6`. Both
numbers use the same denominator. The alert value is the fragmented share, `1 - in_use/total`,
and the alert fires above 0.6.

The alert text says "database size in use … is X% of the actual allocated disk space". That label
is wrong. X is the fragmented share, not the in-use share. The summary line says "less than 50%",
but the threshold is 60%.

The query below gives the in-use ratio. An in-use ratio of 31-37% gives an alert value of 63-69%,
so the alert is correct. The fragmented share is space that etcd still reserves but does not use.

```bash
curl -s -G 'http://victoria-metrics-server.observability.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=etcd_mvcc_db_total_size_in_use_in_bytes/etcd_mvcc_db_total_size_in_bytes' \
  -o /tmp/etcd.json -w '%{http_code}\n'
```

## Classification and fix

This case is not auto-fixable. The operator runs `etcdctl defrag` on each member, one at a time,
so that quorum holds. On Talos, the operator does this through `talosctl` on the control-plane
node. The agent has no access to etcd.

## History

The alert fired on talos-cp-01/02/03 together for about 18.6 h from 2026-09-22. It was RESOLVED
on 2026-09-23 08:02Z. After a defrag, the in-use/total ratio went from about 31-37% to about 85%.
The alert cleared in the same window as the kube-apiserver TargetDown. There was no open case at
2026-10-21. If it fires again, append recurrence entries as `SKILL.md` § Documented cases says.
Older entries: `/opt/data/workspace/cluster-health/archive/etcd-triage.full.md`.

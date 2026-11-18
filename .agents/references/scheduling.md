# Scheduling & Descheduler — home-infra

This file explains why pods land where they do. It also covers two traps that each cost a session
(Forgejo issue #1927).

## The scheduler packs on requests; watch requests, not `kubectl top`

kube-scheduler admits a pod only if the node has unreserved requests left. Actual usage does not
affect admission. A node can show 43% measured CPU and still refuse every new pod, because it is
at 91% requested. This is how `talos-gpu-01` once stalled CI pods while it looked idle in
`kubectl top`.

If a pod does not schedule, compare its requests against the allocatable resources of the node.
Do not use the metrics.

```bash
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
```

Do not "right-size" a request from a `kubectl top` snapshot. Bursty workloads idle near zero
between bursts, so a point sample looks like waste. Measure p95 over a week instead:

```promql
quantile_over_time(0.95, sum by (pod) (rate(container_cpu_usage_seconds_total{pod=~"<app>-[0-9a-f]{6,}-.*"}[5m]))[7d:10m])
```

The p95 measurement showed that transcoding apps use more than a full core while they request
1000m. Jellyfin (now `media/silo`) peaked near 11 cores during transcodes. Such apps are
under-requested, not over-requested. If you cut requests to unblock CI, you starve workloads that
have honest requests.

The pod-name regex is important. kopiur backup Jobs are named `<app>-<timestamp>-<suffix>`. If you
match on `<app>.*`, those Jobs fill the result set.

## `LowNodeUtilization` needs an underutilized node or it silently does nothing

The plugin evicts pods from an overutilized node only when an underutilized node can receive
them. If no node is below the low threshold, the plugin logs this line and exits:

```
"No node is underutilized, nothing to do here, you might tune your thresholds further"
```

It exits even when nodes are over target. This repo ran in that state for months, on absolute
thresholds of 20/50. Every node used more than 20% memory, so the set of underutilized nodes was
always empty.

The plugin now runs with `useDeviationThresholds: true`. The thresholds are not absolute. They
float around the cluster mean: 10% under and 15% over. On a small cluster of similar nodes, the
plugin does nothing when the spread is even. It acts when one node drifts out, which is the only
case where an eviction helps. `evictionLimits.node: 5` limits how many pods one pass can evict
from a node.

The plugin is also request-based on purpose. `metricsUtilization` was removed. Balance by
measured usage cannot see the request packing that blocks scheduling. This plugin exists here to
prevent that failure.

## `kubectl cordon` is not a light-touch operation by default

Cordon adds the taint `node.kubernetes.io/unschedulable:NoSchedule`.
`RemovePodsViolatingNodeTaints` treats that taint like any other taint. It evicts every pod that
does not tolerate it. Without the exclusion below, one cordon evicted 26 pods, including the CNPG
primary (#1927).

The plugin now carries `excludedTaints: [node.kubernetes.io/unschedulable]`. This restores the
documented cordon behaviour: it stops the scheduling of new pods and leaves running pods alone.
The descheduler still enforces real taints. `kubectl drain` is not affected, and it is still the
way to empty a node.

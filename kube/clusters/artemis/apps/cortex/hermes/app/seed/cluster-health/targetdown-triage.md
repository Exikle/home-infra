# TargetDown triage

TargetDown fires once for each down series (`up == 0`). Its description names the job and the
instance.

## Diagnosis recipe

1. Look at the workload first. If the DaemonSet or Deployment is fully ready (7/7 for
   smartctl-exporter), the cause is not a pod. The pod labels follow the chart
   (`app.kubernetes.io/name=prometheus-smartctl-exporter`), so a guessed `app=<job>` selector
   returns nothing.
2. Run `bash /etc/hermes-skills/cluster-health/scripts/targetdown-check.sh <job>`. It prints
   `up{job=...}` per instance, and the `scrapeUrl`, `health` and `lastError` of each vmagent
   target. Service-discovered `up=1` series carry the `container`, `endpoint`, `namespace` and
   `service` labels. A static target has none of them. An `up=0` series without them is a static
   target, which is the usual cause. `lastError` names the real cause (HTTP 500 body, connection
   refused, DNS, size limit).
3. You parse without jq. `/api/v1/targets` is several MB, because each target embeds
   `discoveredLabels`. Never `grep -o` a pattern that can span a `discoveredLabels` block. One such
   grep hung for 900 s. Narrow the result on the server with `&scrapePool=<url-encoded pool>`, for
   example `staticScrape%2Fobservability%2Fsmartctl-exporter-pantheon%2F0`. Or grep short, atomic
   fields only (`"scrapeUrl":"[^"]*"`, `"health":"[^"]*"`, `"job":"[^"]*"`). A VM query value
   looks like `"value":[<ts>,"1"]`. The literal `"up":1` never appears.

## Classification

A healthy workload with a down static target is not auto-fixable. The fix is a Flux scrape-config
edit (observability) or a repair on the host. Report it as `attention` on the `warning` route
("needs human attention"). Do not blame a TargetDown on a pod unless you independently confirm a
pod-level class (CrashLoopBackOff, Evicted, stuck terminating).

## Cases

### smartctl-exporter, static `instance=pantheon` (RESOLVED 2026-08-15)

The static target `http://10.10.99.104:9633/metrics` is the Proxmox host `pantheon`, not a
Kubernetes node. It returned HTTP 500 with "44 error(s)" while smartctl was not able to read the devices
on the host. The 7 service-discovered DaemonSet targets stayed up the whole time. The case was
open about 52 h, with 11 logged recurrences. The fix was on the host and in the scrape
configuration. Healthy state: `up{job="smartctl-exporter"}` 8/8 = 1.

### kube-apiserver, instance talos-cp-02 (RESOLVED 2026-09-23 08:02Z)

The scrape discovers all 3 control-plane endpoints. `https://10.10.99.102:6443/healthz` returned 200. But the vmagent `lastError` said that the `/metrics` response of that node was larger than
`-promscrape.maxScrapeSize` (16777216 bytes). So `up{job="kube-apiserver"}` was 2/3. This case is
not auto-fixable. The fix is to raise `max_scrape_size` on the Flux-managed kube-apiserver scrape
configuration, or the vmagent flag. The case was open about 76 h, with 6 logged observations.
Healthy state: 3/3 = 1.

## Recurrence log (open cases only)

Format and rules are in `SKILL.md` § Documented cases. No open TargetDown case at 2026-10-21. The full history of the two cases above is archived in `/opt/data/workspace/cluster-health/archive/targetdown-triage.full.md`.

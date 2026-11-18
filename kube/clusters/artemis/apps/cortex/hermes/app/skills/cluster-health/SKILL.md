---
name: cluster-health
description: "Cluster health triage, woken by the cluster-health-check.sh pre-check only when it finds something new: verifies the findings against k8s state and notifies via chaski. It changes nothing. Designed for the hermes cron scheduler."
version: "4.0.0"
author: Artemis
license: MIT
platforms: [linux]
metadata:
    hermes:
        tags: [Kubernetes, Monitoring, Alertmanager, Self-Healing, Operations]
        related_skills: [skill-change-pr]
---

# Cluster Health Triage

The cron job runs `/opt/data/scripts/cluster-health-check.sh` every 30 minutes, before you start.
The script already did these sweeps:

- Firing alerts, except Watchdog.
- Nodes that are not Ready or are under pressure.
- Pods that are Pending for more than 10 minutes.
- Scrape targets with `up == 0`, including the static smartctl `pantheon` target.

The script wakes you only in two cases. The findings differ from the last wake, or the same
findings are 4 hours old. A clean cluster never reaches you. The script sends that `info` itself.

Your input is the Script Output block at the top of the prompt. It holds a `findings:` list with
one `- ` line per finding. Start from it. Do not do the sweeps again. If there is no such block
(a manual run), run `bash /opt/data/scripts/cluster-health-check.sh` and use its output. If the
output ends with `{"wakeAgent": false}`, there is nothing to triage. Then reply `[SILENT]`.

Find broken things and send exactly one chaski notification. You report. You never change the
cluster.
Alertmanager already pages in real time. This run is an extra audit.

## Rules for every command (the security scanner stalls cron runs that break them)

- Never pipe into an interpreter (`curl … | python3`). Never run `python3 -c` / `-e`. Write
  with `curl -o <file>`. Then, in a separate step, use `read_file` or `grep` on the file. `jq` is
  not installed.
- Do not use heredocs or inline JSON in the shell. Build JSON with `write_file`, then send it with
  `curl --data @file`.
- `write_file` refuses `/tmp`. Write files only under `/opt/data/workspace/`. `curl -o /tmp/...`
  is fine.
- The directory of this skill, `/etc/hermes-skills/cluster-health/`, is read-only. Never write
  there. Everything that you append to or rewrite lives in `/opt/data/workspace/cluster-health/`
  (called the state dir below) or in `/opt/data/workspace/.health-reports/`.
- Do arithmetic (alert age) in bash:
  `age_h=$(( ($(date +%s) - $(date -d '<startsAt>' +%s)) / 3600 ))`.
- Read the cluster with the k8s MCP tools. They are read-only: the server hides every tool that
  changes a resource. There is no `kubectl` in the image.
- MCP quirks: if you do not use `labelSelector`, `fieldSelector` or `namespace`, leave it out.
  An empty string fails validation. `k8s_resources_list` always needs both `apiVersion` and
  `kind`, for example `{"apiVersion": "v1", "kind": "Node"}`. The call fails without them.

Endpoints: alertmanager `http://alertmanager.observability.svc.cluster.local:9093`,
VictoriaMetrics `http://victoria-metrics-server.observability.svc.cluster.local:8428`, chaski
`http://chaski.observability.svc.cluster.local:8080`.

## Step 1: Read the findings

Each finding line has one of these forms:

- `alert <name> severity=… ns=… target=… since <startsAt>`
- `node … is not Ready`
- `node … has <Pressure>`
- `pod <ns>/<pod> Pending for over 10m`
- `scrape target down: job=… instance=…`
- `check-failed: …`

Work through them in that order of importance.

- `check-failed: …` means that the script did not reach alertmanager or VictoriaMetrics. So
  its sweep for that part did not run. Test the endpoint yourself with `curl` (endpoints above).
  If the endpoint answers now, do that sweep with the k8s tools. If it stays down, report status
  `failed`.

## Step 2: Verify against live state

For every finding, make sure that its claim is true with the k8s tools (pod state, conditions,
events, logs). Drop findings that already corrected themselves. Never trust an alert line alone.

- KubePodCrashLooping: `1/1 Running` is not proof of recovery. Keep the alert if `restartCount`
  matches a loop since `startsAt`. Treat the alert as resolved only when two things are true.
  `restartCount` stopped going up for a full evaluation window, and the last restart is older
  than 5 minutes.
- TargetDown or scrape target down: run
  `bash /etc/hermes-skills/cluster-health/scripts/targetdown-check.sh <job>`. The alert groups by
  (job, namespace, service). A static scrape target has no namespace/service labels. So "100%
  down" can mean one stale target while the rest of the job is healthy. A healthy workload with a
  down static target is not auto-fixable. The fix is a Flux scrape-config edit or a host repair.
  Detail: `/opt/data/workspace/cluster-health/targetdown-triage.md`.
- Pending pod: the script already ignores pods younger than 10 minutes. Find the waiting reason
  (ImagePullBackOff, Unschedulable, a PVC that will not bind).
- Node finding: read `k8s_nodes_top`. Describe the CPU and memory readings with
  `/etc/hermes-skills/cluster-health/references/node-baselines.md`. Expect 7 nodes, and count
  them from the live result.

### Documented cases

Before you diagnose a finding from the start, look for the same `alertname` + `job`/instance in
two places. Read `/opt/data/workspace/cluster-health/resolved-cases.md` (open and resolved
tables), and run `ls /opt/data/workspace/cluster-health/`. Also compare every row under Open
cases with the findings. You can append to the files in the state dir. They are not part of the
skill.

- Finding matches a documented open case: verify it live again. Then report it as "previously
  triaged — fix pending". Give the known fix, the pending time in hours (`startsAt` to now) and
  the recurrence count (`grep -c '^- 20' /opt/data/workspace/cluster-health/<file>.md`). Example:
  `TargetDown smartctl-exporter — previously triaged, fix pending ~40h, 12th recurrence`. Append
  one log entry (format below). If the case has no Open cases row, add one.
- Open-case row is no longer in the findings: make sure that the fix is real from live sources.
  The absence of the alert is not enough. For TargetDown, all series of `up{job="<job>"}` must be
  1, including the static instance that was stale. Append a RESOLVED log entry. Move its row to
  the Resolved table in `resolved-cases.md` (state dir). Name the resolution in the `info`
  notification. This run is not `[SILENT]`.
- Row in the Resolved table with no matching finding: run the verify query of the row once. Put
  one line in `items`, for example
  `"smartctl-exporter TargetDown remains fixed — up{job=...} 8/8 = 1 incl. static instance=pantheon"`.
  Do not append to any log. The absence of the alert does not prove that the fix lasts. The
  query does.
- Not documented: diagnose the finding. Then classify it by Step 3 and notify. If it is a recurring
  alert that needs a human, use `write_file` to write a short `<alert>-triage.md` in the state
  dir.

To make sure that all series = 1 without python, run:

```bash
curl -s --max-time 20 -G 'http://victoria-metrics-server.observability.svc.cluster.local:8428/api/v1/query' \
  --data-urlencode 'query=up{job="<job>"}' -o /tmp/up.json -w '%{http_code}\n'
grep -o '"value":\[[0-9]*,"[0-9]"\]' /tmp/up.json | sort | uniq -c
```

Expect N lines of `[ts,"1"]` and none of `[ts,"0"]`.

Log entry format:
`- <YYYY-MM-DD HH:MMZ> <recurrence #N | RESOLVED>: <alert/instance>, active <N>h; <one line of live evidence>; <N>/<N> nodes Ready.`

Follow these rules for the log:

- Append to the file of the case in the state dir with terminal `echo '<entry>' >> <file>`.
- Keep strict time order. One entry has at most 3 lines.
- Append only when the state changes: a new recurrence, a new resolution, or a different
  sub-condition. A quiet run appends nothing.
- Keep the newest 10 entries per file. If a file has more, run
  `bash /etc/hermes-skills/cluster-health/scripts/trim-triage-log.sh <file> 10 /opt/data/workspace/cluster-health/archive`,
  then `mv <file>.new <file>`.

### Sibling runs and divergence

If `write_file` warns `was modified by sibling subagent`, another run wrote the same report. Use
`read_file` on the JSON of the sibling and compare it with yours:

- If `status`, `stats` and `items` are all the same, do not POST. Reply `[SILENT]`.
- If your live reading is different, POST your own message with the current correct reading.
  Examples of a different reading: a node metric moved to another band in `node-baselines.md`, a
  pending pod got scheduled, the count of `up{}` series is different, or you verified a case
  again that the sibling did not. Never say that a reading is "back in" a band when its number is
  outside that band.

## Step 3: Classify pod-level findings

You have no tool that deletes or scales anything, so every finding goes to the operator. For a
pod-level class, name the pod and its controller in `items`, so the operator can act fast:

| Class                                                                     | What to report                                           |
| ------------------------------------------------------------------------- | -------------------------------------------------------- |
| `CrashLoopBackOff` pod                                                    | the pod, its restart count and the last log error        |
| Evicted pod                                                               | the pod and the eviction reason                          |
| Stuck terminating pod (`metadata.deletionTimestamp` set, finalizer stuck) | the pod, how long it has been terminating, the finalizer |
| Deployment at 0 ready replicas                                            | the Deployment and why its pods are not ready            |

Do not blame a `TargetDown` on a pod unless you independently confirm a pod-level class.

If a tool refuses a call, notify and stop. Do not look for another route.

## Step 4: Notify (one message per run)

chaski owns the formatting. Supply data only: no HTML, no markdown, no bullets. chaski escapes
markup and shows it as plain text.

1. Get the timestamp: `date -u +%Y%m%dT%H%MZ`.
2. Use `write_file` to write `/opt/data/workspace/.health-reports/cluster-health-<timestamp>.json`:

```json
{
    "skill": "cluster-health",
    "status": "ok",
    "summary": "3 alerts fired; 1 resolved, 2 need a human.",
    "stats": { "alerts": 3, "resolved": 1, "fixed": 0, "attention": 2 },
    "items": [
        "KubePodCrashLooping media/sonarr — 14 restarts, last error: database is locked",
        "TargetDown smartctl pantheon — probe failed, endpoint genuinely down"
    ],
    "url": "https://alertmanager.dcunha.io/alerts"
}
```

3. POST it (`ROUTE` is `info`, `warning` or `critical`):

```bash
curl -s --max-time 15 -X POST -H 'Content-Type: application/json' \
  --data @/opt/data/workspace/.health-reports/cluster-health-<timestamp>.json \
  "http://chaski.observability.svc.cluster.local:8080/hooks/$ROUTE" \
  -o /tmp/chaski_resp.txt -w 'HTTP %{http_code}\n'
```

HTTP 200 with an empty body means that chaski relayed it. If you get a timeout, a 5xx or any
other non-200 response, write the same summary to
`/opt/data/workspace/.health-reports/$(date -I).md` instead.

| Key       | Type   | Rule                                                                                                       |
| --------- | ------ | ---------------------------------------------------------------------------------------------------------- |
| `skill`   | string | the literal `cluster-health`                                                                               |
| `status`  | string | exactly `ok`, `attention` or `failed`. Anything else renders `MALFORMED`                                   |
| `summary` | string | one plain-text sentence, at most 140 chars                                                                 |
| `stats`   | object | integers only, keys exactly `alerts`, `resolved`, `fixed`, `attention`. 0, never null. `fixed` is always 0 |
| `items`   | array  | plain one-line strings. Only the first 4 render. The rest collapse to "…N more"                            |
| `url`     | string | must start with `https://`, or chaski drops it                                                             |

Status: `ok` means that nothing needs a human. `attention` means that something is left for the
operator. `failed` means that the audit itself did not complete.

Route: use `info` for `ok` and `warning` for `attention`. Use `critical` only for `failed` with a
degraded cluster.

`items` rules:

- Order by importance: alerts that need a human first, then routine sweep lines. A routine line
  must not push a live problem out of the first 4.
- If every finding corrected itself, still send `info` with zeroed stats. Put
  `"N/N nodes Ready, no pressure"` in `items`, plus one line per resolved case that you verified
  again. Compare a reading that is high but needs no action against `node-baselines.md`, and say
  so.

## Final response

- Reply exactly `[SILENT]` and nothing else when nothing is new for the operator. That is status
  `ok` with no resolution and no divergence, or a redundant sibling run. The chaski
  `info` keeps the run visible. `[SILENT]` only stops a duplicate delivery.
- Otherwise, reply with a short plain report: `attention` items, a RESOLVED case, or a
  band change. Never combine `[SILENT]` with other text.

## Hard rules

- Never change a resource. Report it instead.
- Do not edit this skill, because it is read-only. To propose a change, follow skill
  `skill-change-pr`.
- Compare alerts with live state before you act on them.

## Network map (lab subnet 10.10.99.0/24)

| IP               | Host                                                                |
| ---------------- | ------------------------------------------------------------------- |
| 10.10.99.99      | apiserver VIP                                                       |
| 10.10.99.100     | atlas, TrueNAS (NFS `/mnt/atlas/media`)                             |
| 10.10.99.101-103 | talos-cp-01/02/03 (metal control plane)                             |
| 10.10.99.104     | pantheon, Proxmox host (runs talos-w-01/02 and talos-gpu-01 as VMs) |
| 10.10.99.201-204 | talos-w-01, talos-w-02, talos-gpu-01, ymir                          |

An IP outside this table is not always a stale configuration, because it can be an external
host. For a static scrape target, follow these steps:

1. Read its `scrapeUrl` and `lastError` from vmagent. `targetdown-check.sh` prints them.
2. Probe it once with `curl -s --max-time 5 -o /dev/null -w '%{http_code}\n' http://<host>:<port>/metrics`.
3. Call it stale only after the probe fails.
4. If the endpoint is really down, send a `warning`. The fix is outside the cluster.

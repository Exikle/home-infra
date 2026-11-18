---
name: cluster-status
description: Take a fast read on overall cluster health (failing pods, unready Flux resources, node and storage state) and report what is actually broken. Use for "cluster status", "what's broken", "health check", "anything down", or "quick status". Covers Artemis and Frostlink.
---

# Skill: Cluster Status

This skill is a quick, read-only health digest of home-infra. It gives a 🟢/🟡/🔴 summary for
each layer. The commands below run against Artemis. § Frostlink says how to point them at Frostlink.

## Run

```bash
# Flux — not-ready resources
flux get kustomizations -A --status-selector ready=false
flux get helmreleases -A --status-selector ready=false

# Nodes
kubectl get nodes -o wide

# Unhealthy pods: phase not Running or Succeeded, or Running with a container that is not ready (CrashLoopBackOff)
kubectl get pods -A -o go-template='{{range .items}}{{$p := .}}{{if ne .status.phase "Succeeded"}}{{if ne .status.phase "Running"}}{{$p.metadata.namespace}}/{{$p.metadata.name}}  phase={{$p.status.phase}}{{"\n"}}{{else}}{{range .status.conditions}}{{if and (eq .type "Ready") (ne .status "True")}}{{$p.metadata.namespace}}/{{$p.metadata.name}}  phase=Running  waiting={{range $p.status.containerStatuses}}{{if .state.waiting}}{{.state.waiting.reason}} {{end}}{{end}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}'

# Recent warning events
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20

# Flux suspended resources
kubectl get kustomizations,helmreleases,ocirepositories -A -o jsonpath='{range .items[?(@.spec.suspend==true)]}{.kind}/{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

The pod command and the suspended-resources command print nothing when nothing is wrong.

The pod command reads the pod's `Ready` condition, not only its phase. A pod in
`CrashLoopBackOff` stays in phase `Running`, so a filter on phase alone hides it. The command
prints the waiting reason of each container, for example `CrashLoopBackOff` or
`ImagePullBackOff`. It skips Completed (Succeeded) job pods. It still prints a Failed job pod.

The suspended-resources command reads `spec.suspend` directly. `resume-ks` uses the same filter.
Do not use `flux get all -A | grep -i suspend`. `flux get` prints `True` or `False` in its
SUSPENDED column, so the `grep` matches only the header lines and never finds a suspended object.

If local kubectl is not available, use the `-ops` k8s MCP tools. List them and match on the server
and tool portion (resources list/get, events list), as `.agents/instructions/tooling.md` § MCP
servers describes.

## Frostlink

Frostlink is a single node (`frostlink`, ARM64, Oracle Cloud). The MCP k8s tools point at
Artemis, so there is no MCP fallback. Add `--context frostlink` to every command above. A bare
`kubectl` or `flux` in an agent shell hits Artemis. A suspended root or app is a finding, not
noise.

## Output Format

```
## Cluster Status — HH:MM ET

| Status | Layer       | Notes                                         |
|--------|-------------|-----------------------------------------------|
| 🟢     | Flux        | All kustomizations + helmreleases ready       |
| 🟡     | Pods        | 1 pending: foo-bar-xxx in media               |
| 🔴     | Nodes       | talos-w-02 NotReady (15m)                     |
| 🟢     | Events      | No new warnings in the last 20 events         |
```

## Layers (check in order)

1. Flux: kustomizations and helmreleases that are not Ready, and any resource that is Suspended.
2. Nodes: NotReady nodes. `kubectl get nodes` lists every node (ymir included).
3. Pods: pods that are not Running, and Running pods with a container that is not ready. Skip
   Completed (Succeeded) job pods.
4. Events: the 20 most recent Warning events. The command sorts by time. It does not filter by
   time, so read the age of each event.

## Status Key

- 🟢 All clear
- 🟡 Degraded or non-critical issue
- 🔴 Down, or a blocking issue that requires action

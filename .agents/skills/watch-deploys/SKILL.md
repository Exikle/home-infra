---
name: watch-deploys
description: Watch an in-flight deployment or Flux reconciliation until it settles or fails, reporting state transitions as they happen. Use for "watch the deploy", "monitor the rollout", "keep an eye on flux", or when a change was just pushed and its landing needs following. Covers Artemis and Frostlink.
---

# Skill: Watch Deploys

This skill watches the cluster state and reports only the changes. Use it with
`/loop 30s /watch-deploys` while a deployment is in progress.

Each tick shows only what changed since the last tick, not the full cluster state.

The commands below name `--context artemis`. On Frostlink, use `--context frostlink` instead. The
MCP k8s tools point at Artemis, so Frostlink has no MCP fallback.

## State Cache

Store the previous snapshot at `<scratchpad>/watch-deploys-<cluster>.json`. `<scratchpad>` is the
scratchpad folder of the session. `<cluster>` is `artemis` or `frostlink`, so that a run on one
cluster does not overwrite the cache of the other. On the first run (no cache), show the full
current state as the baseline, and write the cache.

## What to Track

Read only the fields that the delta logic compares. A full `-o json` of every pod on every tick
floods the context.

```bash
# Flux snapshot
flux get kustomizations -A --context artemis
flux get helmreleases -A --context artemis

# Pod snapshot
kubectl get pods -A --context artemis -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount

# Node snapshot
kubectl get nodes --context artemis
```

On Artemis, if local kubectl is not available, use the `-ops` k8s MCP tools. List them, and match
on the server and tool portion (pods list, resources list), as `.agents/instructions/tooling.md`
§ MCP servers describes.

## Delta Logic

Compare the current snapshot with the cached snapshot:

| Change type                                 | What to show                               |
| ------------------------------------------- | ------------------------------------------ |
| Kustomization/HelmRelease: NotReady → Ready | `RECOVERED: <name> (<ns>)`                 |
| Kustomization/HelmRelease: Ready → NotReady | `BROKE: <name> (<ns>) — <reason>`          |
| Kustomization/HelmRelease: newly Suspended  | `SUSPENDED: <name> (<ns>)`                 |
| Pod restart count increased                 | `RESTARTED: <pod> (<ns>) — restarts: N→M`  |
| Pod phase changed                           | `PHASE CHANGE: <pod> (<ns>) — <old>→<new>` |
| Node readiness changed                      | `NODE: <name> — Ready→NotReady`            |

## Output Format

```
Tick [20:14:32 ET] — Δ since 20:14:02

RECOVERED:  immich (media) HelmRelease → Ready
BROKE:      komf (media) HelmRelease → Failed: "container image not found"
RESTARTED:  memini-xxx-yyy (cortex) restarts: 0→1

✓ Nodes: all ready
✓ No new Flux suspensions
```

If nothing changed, write: `✓ No changes since 20:14:02`

## Cadence

- Active deploy: `/loop 30s /watch-deploys`.
- Idle monitoring: `/loop 2m /watch-deploys`.
- Stop when all resources are back to Ready.

---
name: watch-deploys
description: Watch an in-flight deployment or Flux reconciliation until it settles or fails, reporting state transitions as they happen. Use for "watch the deploy", "monitor the rollout", "keep an eye on flux", or when a change was just pushed and its landing needs following. Scoped to the Frostlink cluster.
---

# Skill: Watch Deploys

Delta-aware cluster state watcher. Use with `/loop 30s /watch-deploys` during active deployments.

Each tick shows only what **changed** since the last tick — not the full cluster state.

## State Cache

Store the previous snapshot as `frostlink-watch-deploys.json` in the session scratchpad (not `/tmp`). On first run (no cache), show full current state as the baseline and write cache.

## What to Track

```bash
flux get kustomizations -A --context frostlink
flux get helmreleases -A --context frostlink
kubectl get pods -A -o json --context frostlink
kubectl get nodes -o json --context frostlink
```

The MCP k8s tools point at Artemis; there is no fallback to them.

## Delta Logic

Compare current snapshot to cached snapshot:

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

RECOVERED:  <app> (<ns>) HelmRelease → Ready
BROKE:      <app> (<ns>) HelmRelease → Failed: "<reason>"
RESTARTED:  <pod> (<ns>) restarts: 0→1

✓ Nodes: all ready
✓ No new Flux suspensions
```

If nothing changed: `✓ No changes since 20:14:02`

## Cadence

- Active deploy: `/loop 30s /watch-deploys`
- Idle monitoring: `/loop 2m /watch-deploys`
- Stop when all resources are back to Ready

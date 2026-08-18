# Reference: Flux Patterns — Frostlink

## Core Workflow

Test live before committing — `main` goes directly to production:

```bash
just kube apply-ks <ns> <ks-name>   # apply live; wait for user confirmation before committing
just kube sync gitrepo               # force Flux to pull from git
just kube sync hr                    # force-sync all HelmReleases
just kube sync ks                    # force-sync all Kustomizations
just kube sync es                    # force-sync all ExternalSecrets
just kube sync ocirepo               # force-sync all OCIRepositories
```

## Stuck HelmRelease

```bash
flux suspend helmrelease <app> -n <ns>
kubectl delete secret -n <ns> -l name=<app>,owner=helm
flux resume helmrelease <app> -n <ns>
```

## Force Reconcile

```bash
flux reconcile kustomization <name> -n <namespace>
```

Kustomizations live in their **target namespace** (e.g. `network`, `fediverse`), NOT always `flux-system`.

## Key Rules

- `prune: false` on `flux-instance` Kustomization — never prune Flux itself
- `dependsOn` must list actual runtime dependencies, not just chart sources
- `interval: 1h` is standard; `retryInterval: 1m` for fast retries on failure

## Cross-Namespace Kustomization Gotchas

When a `Kustomization` lives outside `flux-system` (e.g. in `fediverse` or `network`), both references must be explicit:

```yaml
spec:
    sourceRef:
        kind: OCIRepository
        name: flux-system
        namespace: flux-system # REQUIRED — omitting causes "OCIRepository not found"
    dependsOn:
        - name: cert-manager
          namespace: cert-manager # REQUIRED for cross-namespace deps
```

Missing either causes a silent "not found" reconciliation failure.

## flate `dependsOn` Namespace

`just kube apply-ks` uses flate, which resolves dependencies by `targetNamespace`. Cross-namespace refs require `namespace: <targetNamespace>` in `dependsOn`:

```yaml
dependsOn:
    - name: cert-manager
      namespace: cert-manager
    - name: onepassword-connect
      namespace: external-secrets
```

Without the `namespace:` field, flate looks in the current ks's own `targetNamespace` and fails silently.

## CRD Timing Race

When a Kustomization deploys both a HelmRelease (which installs CRDs) and resources that depend on those CRDs, Flux applies everything in one shot — before Helm has run.

**Fix**: Force-reconcile the affected Kustomization after the HelmRelease is healthy:

```bash
flux reconcile kustomization <name> -n <namespace>
```

## kopiur CRs stall `wait: true` health checks

kopiur writes `status.observedGeneration` on a `SnapshotSchedule` at its **first** reconcile and
never again. Edit the schedule spec afterwards and the object sits at
`generation != observedGeneration` permanently. kstatus reads that as `InProgress`, so a
Kustomization with `wait: true` hangs on health checks for the full timeout — every cycle,
indefinitely. `fediverse/apoci` flapped `DependencyNotReady` 58128 times over 12 days on exactly
this, and while stuck on a stale revision it silently re-applied an old cron over a change.

- **`healthCheckExprs` does not help.** The generation precondition is evaluated *before* the CEL
  expressions, so the stale field still wins. Verified live, not assumed.
- **Fix: drop `wait: true` and gate on the HelmRelease** via explicit `spec.healthChecks` — that
  is what "the app is up" actually means. Applied to `fediverse/apoci`, `fediverse/gotosocial`
  and `matrix/continuwuity`; the latter two carried the same latent fault and only escaped it
  because their schedules had never been edited.
- `SnapshotPolicy` tracks `observedGeneration` correctly. `Restore` does **not**, but the
  component annotates it `kustomize.toolkit.fluxcd.io/ssa: ignore`, so Flux reports it `skipped`
  and excludes it from health checks. Artemis-Cluster lacked that annotation and stalled
  `arcade/eco` for 24 days the same way — keep it.
- Diagnostic: `kubectl get snapshotschedule -A -o json` and compare
  `.metadata.generation` against `.status.observedGeneration`.

## ks.yaml changes cannot be tested locally

`just kube apply-ks <ns> <ks>` renders and applies the app **path** — it does not touch the
Kustomization CR itself. Patching the live CR does not work either: `frostlink-dev` reverts it
within seconds, and suspending `frostlink-dev` does not help because flux-operator recreates it
from the FluxInstance. **Pushing is the only way to test a ks.yaml change**, so budget for
verifying after the push rather than before. Two test results were silently invalidated by this
before it was noticed.

## Common Anti-Patterns

- **Sharing OCIRepository**: every app needs its own — never reuse
- **HTTPRoute as standalone file**: goes in helmrelease values
- **SOPS**: fully removed — do not introduce
- **External hostnames for cluster traffic**: always `svc.cluster.local`
- **`git add .` / `git add -A`**: always stage specific files by name

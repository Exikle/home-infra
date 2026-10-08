# Reference: Flux Patterns — Frostlink

## Core Workflow

Test live before committing — `main` goes directly to production:

```bash
just kube suspend-ks flux-system frostlink-dev  # REQUIRED — root
just kube suspend-ks <ns> <ks-name>             # REQUIRED — target
just kube apply-ks <ns> <ks-name>               # apply live; wait for user confirmation before committing
# ...commit and push, then wait for the OCI artifact build to go green...
just kube sync ocirepo                          # force-sync all OCIRepositories — repeat until the digest moves
just kube resume-ks flux-system frostlink-dev   # root FIRST
just kube resume-ks <ns> <ks-name>              # then the target
```

Other force-sync targets:

```bash
just kube sync hr                   # all HelmReleases
just kube sync ks                   # all Kustomizations
just kube sync es                   # all ExternalSecrets
```

### There is no `GitRepository` — the source is OCI

`FluxInstance/flux` syncs `kind: OCIRepository` from `oci://registry.frostlink.dev/exikle/frostlink`
at `interval: 1m`, built and pushed by CI. `kubectl get gitrepository -A` returns nothing, so
**`just kube sync gitrepo` has no live target** — it is a no-op that looks like it worked. The
only `kind: GitRepository` anywhere in the repo is
`kubernetes/components/alerts/alertmanager/alert.yaml`, where it is a notification `eventSource`
selector, unrelated to Kustomization sources. All 53 `ks.yaml` use
`kind: OCIRepository, name: flux-system, namespace: flux-system`.

**Do not sync before CI has rebuilt the artifact.** The OCIRepository is built from the pushed
commit; syncing immediately after `git push` re-resolves the **pre-commit** digest and silently
reverts what you just landed. `✔ applied revision` alone proves nothing — check that the
`flux-system` digest actually changed:

```bash
kubectl -n flux-system get ocirepository flux-system \
  -o jsonpath='{.status.artifact.revision}{"\n"}'
```

Live anchors (verified 2026-08-21): distribution `2.x`; controllers source `v1.9.4`, kustomize
`v1.9.4`, helm `v1.6.3`, notification `v1.9.3`. Kustomization API `kustomize.toolkit.fluxcd.io/v1`,
HelmRelease `helm.toolkit.fluxcd.io/v2`, OCIRepository `source.toolkit.fluxcd.io/v1`,
ExternalSecret `external-secrets.io/v1`.

### Suspend before a test-apply — same as Artemis

`apply-ks` suspends nothing. **Both suspend recipes are narrow** — they act only on the
Kustomization you name, so the root is always a separate call. Going in, order does not matter;
`suspend-ks` on a child only warns if the root is still running. Coming out, order is enforced:
`resume-ks` refuses to wake a child while the root is still suspended, because the child would
reconcile its old spec and write stale values straight back. It also warns about anything left
suspended when it finishes — read its last line. Never resume before CI has rebuilt the artifact.

**Suspending the root survives — flux-operator does not recreate it.** An earlier version of this
file said it did. Checked read-only on 2026-10-07, against both clusters:

- `FluxInstance/flux` inventory holds only `Kustomization/flux-system` and
  `OCIRepository/flux-system`. `frostlink-dev` is not in it, and has no ownerReference.
- `frostlink-dev` carries `kustomize.toolkit.fluxcd.io/name: flux-system` — it is applied by the
  `flux-system` Kustomization from `kubernetes/flux/sync/cluster.yaml`, which sets no `suspend`.
- Its `kustomize-controller` server-side-apply field set does not include `spec.suspend`, so a
  re-apply leaves a `flux suspend` in place.
- Artemis's `artemis-cluster` is wired identically on every point above, and its two-suspend
  sequence is routine there.

Check it yourself:

```bash
kubectl get fluxinstance flux -n flux-system --context frostlink -o jsonpath='{.status.inventory.entries[*].id}'
kubectl get ks frostlink-dev -n flux-system --context frostlink --show-managed-fields -o yaml
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

- `prune: false` on `flux-instance` Kustomization — never prune Flux itself. `kube-system/coredns`
  is the only other `prune: false`; everything else prunes.
- `dependsOn` must list actual runtime dependencies, not just chart sources
- `interval: 1h` is standard — 50 of 53 `ks.yaml` use it, 3 use `30m`
- **`retryInterval: 1m` is injected by the root Kustomization's patch block**, so an explicit one
  in a child is redundant. Only 8 of 53 set it by hand (2 of those override to `2m`); the rest
  inherit `1m` whether or not the file says so. Do not add it "because it's missing" — it isn't.

## The root Kustomization overwrites every child's `spec.patches`

`kubernetes/flux/sync/cluster.yaml` (the root Kustomization, named **`frostlink-dev`**, in
`flux-system`) carries a `patches:` block targeting `kustomize.toolkit.fluxcd.io/Kustomization`
with `metadata.name: _` — i.e. **every child `ks.yaml` in the repo**. It sets `deletionPolicy`,
`retryInterval`, and a nested `spec.patches` that applies HelmRelease install/upgrade/rollback
defaults.

Because it sets `spec.patches` wholesale, **a `patches:` block written into an app's own
`ks.yaml` is silently replaced.** No error, no warning — the patch just never applies, and the
symptom surfaces downstream as "my override isn't taking effect". `flate` does not evaluate the
parent patch either, so `just kube render-local-ks` makes the override look like it worked.

Put per-app kustomize overrides in the app's own `app/kustomization.yaml` (`patches:` there is
evaluated by the child's own kustomize build and is untouched by the parent). Do not add
`spec.patches` to a `ks.yaml`. Identical mechanism and identical rule on Artemis, where it cost a
full afternoon during a namespace move before it was identified.

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

- **`healthCheckExprs` does not help.** The generation precondition is evaluated _before_ the CEL
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
Kustomization CR itself. Patching the live CR does not work either: a running `frostlink-dev`
reverts it. (flux-operator does **not** recreate `frostlink-dev` — § Suspend before a test-apply —
but whether a CR patch holds under a suspended root has not been tested.) **Pushing is the only
proven way to test a ks.yaml change**, so budget for
verifying after the push rather than before. Two test results were silently invalidated by this
before it was noticed.

## Common Anti-Patterns

- **Sharing OCIRepository**: every app needs its own — never reuse
- **HTTPRoute as standalone file**: goes in helmrelease values
- **SOPS**: fully removed — do not introduce
- **External hostnames for cluster traffic**: always `svc.cluster.local`
- **`git add .` / `git add -A`**: always stage specific files by name

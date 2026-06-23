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
        kind: GitRepository
        name: flux-system
        namespace: flux-system # REQUIRED — omitting causes "GitRepository not found"
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

## Common Anti-Patterns

- **Sharing OCIRepository**: every app needs its own — never reuse
- **HTTPRoute as standalone file**: goes in helmrelease values
- **SOPS**: fully removed — do not introduce
- **External hostnames for cluster traffic**: always `svc.cluster.local`
- **`git add .` / `git add -A`**: always stage specific files by name

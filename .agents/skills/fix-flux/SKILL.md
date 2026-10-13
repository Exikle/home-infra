---
name: fix-flux
description: Diagnose and repair a stalled Flux reconciliation — a HelmRelease stuck or not progressing, a Kustomization not reconciling, an OCIRepository not resolving, or an ExternalSecret not syncing. Use for "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "ExternalSecret not syncing", or when flux get shows a resource not ready. Scoped to a known-stalled Flux resource in the Frostlink cluster. If you do not yet know what is wrong, start with `cluster-status`.
compatibility: Diagnosis is read-only. The only cluster writes are the documented unstick steps (suspend/resume, deleting a failed Helm release secret, a forced reconcile). Manifest fixes go through git or `just kube apply-ks`, never an ad-hoc kubectl edit.
---

# Skill: Fix Flux

Diagnose and fix Flux reconciliation problems in Frostlink. Every `kubectl`/`flux` command pins
`--context frostlink`.

The unstick procedures (stuck HelmRelease, forced reconcile, CRD timing race) are in
`.agents/references/flux-patterns.md`: § Stuck HelmRelease, § Force Reconcile, § CRD Timing Race.
Read them before repairing.

## Step 1 — Identify what is broken

```bash
flux get all -A --status-selector ready=false --context frostlink
```

App Kustomizations live in their **target namespace** (`fediverse`, `network`, …), not
`flux-system`; only the root `frostlink-dev` is in `flux-system`. The Kustomization name is
`metadata.name` in the app's `ks.yaml`, not always `<app>`:

```bash
grep "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml
```

## Step 2 — Diagnose by symptom

### HelmRelease stuck (install/upgrade retrying)

```bash
flux describe helmrelease <app> -n <namespace> --context frostlink
kubectl get events -n <namespace> --sort-by='.lastTimestamp' --context frostlink
```

If it is only retrying a failed release, apply § Stuck HelmRelease.

### Kustomization not reconciling

```bash
flux describe kustomization <ks-name> -n <namespace> --context frostlink
```

- `dependsOn` target not Ready: follow the chain.
- Schema or substitution error: `just kube render-local-ks <namespace> <ks-name>` reproduces it offline.
- New artifact not picked up: the source is an `OCIRepository` (there is no `GitRepository`);
  `just kube sync ocirepo`.
- "no matches for kind": CRD timing race, § CRD Timing Race (and check `dependsOn` lists the CRD provider).

### ExternalSecret not syncing / empty secret

```bash
kubectl describe externalsecret <app> -n <namespace> --context frostlink
kubectl get pods -n external-secrets --context frostlink
just kube sync es
```

Usual causes: a 1Password field name that does not match the template `{{ .FIELD_NAME }}`
exactly, or `onepassword-connect` unhealthy. Do not print the Secret's values.

### Image pull errors

```bash
kubectl describe pod <pod> -n <namespace> --context frostlink
```

Check the tag exists in the registry; if rate limited, wait.

### Values not applying after a push

```bash
flux reconcile helmrelease <app> -n <namespace> --with-source --context frostlink
```

## Step 3 — Force a reconcile

```bash
just kube sync ocirepo
flux reconcile kustomization <ks-name> -n <namespace> --with-source --context frostlink
flux reconcile helmrelease <app> -n <namespace> --context frostlink
```

## Step 4 — Verify

```bash
flux get helmrelease <app> -n <namespace> --context frostlink
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app> --context frostlink
kubectl logs -n <namespace> deployment/<app> --tail=20 --context frostlink
```

If several apps in one namespace are broken, find the shared cause (a common `dependsOn`, the
namespace's secret store) rather than reconciling each.

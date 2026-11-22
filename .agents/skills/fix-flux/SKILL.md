---
name: fix-flux
description: Diagnose and repair a stalled Flux reconciliation — a HelmRelease stuck or not progressing, a Kustomization not reconciling, an OCIRepository not resolving, or an ExternalSecret not syncing. Use for "flux is broken", "HelmRelease stuck", "kustomization not reconciling", "ExternalSecret not syncing", or when flux get shows a resource not ready. Covers Artemis and Frostlink.
---

# Skill: Fix Flux

This skill diagnoses and fixes Flux reconciliation faults in home-infra.

On Frostlink, add `--context frostlink` to every `kubectl` and `flux` command. Bare commands hit
Artemis, and the MCP k8s tools do too. In every task path below, `<cluster>` is `artemis` or
`frostlink`. The source is an `OCIRepository` on Frostlink too. The Kustomizations of Flux itself
are in `flux-system` (`kubectl get ks -n flux-system --context <cluster>`).

> Read `.agents/references/flux-patterns.md` before you diagnose. It covers fixes for a stuck
> HelmRelease, cross-namespace traps, and the CRD timing race.

Goal: find why one Flux resource does not reconcile, and fix that cause.

Success means that the named resource reports Ready with the current revision, and you can name the
cause. A retry that made it go green is not enough.

Stop when that resource is Ready. These are forbidden:

- Do not `flux delete`.
- Do not delete PVCs or namespaces to clear a stuck state.
- Do not force-reconcile the flux-system OCIRepository directly after a push. CI builds the
  artifact, so a reconcile before the build finishes applies the old tree. This includes
  `flux reconcile ... --with-source` on a Kustomization, which reconciles that same source.

If you need one of these, escalate to the user instead.

The source is the OCIRepository `flux-system`, cut into one `ExternalArtifact` per app. There is
no GitRepository. App Kustomizations live in the namespace of their app, not in `flux-system`. A
fix that changes manifests follows
`.agents/instructions/commit-style.md` § The sequence, in a worktree
(`mise run //:wt:new fix/<slug>`).

## Step 1: Identify What Is Broken

```bash
flux get all -A --status-selector ready=false
kubectl get helmrelease -A | grep -v "True"
kubectl get kustomization -A | grep -v "True"
```

## Step 2: Diagnose by Symptom

### Stuck HelmRelease (install/upgrade retrying)

```bash
flux describe helmrelease <app> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

Fix:

1. Retry it: `mise run //kube/clusters/<cluster>:unstick-hr <namespace> <app>`. The task forces a
   one-off install or upgrade and resets the failure count.
2. If it is still stuck, ask the user. Then run
   `mise run --yes //kube/clusters/<cluster>:reset-hr <namespace> <app>`. The task deletes the Helm
   release history and reinstalls. Rollback to earlier revisions is lost.

### Kustomization Not Reconciling

First, look up the exact Kustomization name. It is the `metadata.name` in `ks.yaml`. It is not
always `<namespace>-<app>`. Every app, shared or not, keeps its `ks.yaml` in the cluster tree:

```bash
grep -n "^  name:" kube/clusters/<cluster>/apps/<namespace>/<app>/ks.yaml
flux describe kustomization <ks-name> -n <namespace>
```

Common causes:

- A `dependsOn` target is not Ready. Read the dependency chain.
- A schema validation error. Run `mise run //kube/clusters/<cluster>:render-ks <namespace> <ks-name>`
  to catch it locally.
- The source is behind. First make sure that the `Push OCI Artifact` run for the commit is green.
  Then run `mise run //kube/clusters/<cluster>:sync-flux ocirepo flux-system`.
- The per-app artifact is behind or missing. An app Kustomization reads the `ExternalArtifact`
  named for its app folder, which the `apps` `ArtifactGenerator` in `flux-system` makes from the
  OCIRepository (`.agents/references/app-structure.md` § Per-app artifacts). Read
  `kubectl get externalartifact <app-folder> -n <namespace>` and
  `kubectl describe artifactgenerator apps -n flux-system`.

### ExternalSecret Not Syncing / Empty Secret

```bash
kubectl describe externalsecret <app> -n <namespace>
mise run //kube/clusters/<cluster>:sync-flux es <app>
kubectl get secret <app> -n <namespace> -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
```

The last command lists only the key names. Never print a Secret with `-o yaml` or `-o json`,
because that prints every value.

Common causes:

- A 1Password field name does not match. The exact field name must match the template
  `{{ .FIELD_NAME }}`.
- The onepassword-connect pod is unhealthy. Run `kubectl get pods -n external-secrets`.

### Pod Stuck in ContainerCreating (miroir volume)

This section is for Artemis only.

```bash
kubectl describe pod <pod> -n <namespace> | grep -A5 Events
```

If you see `rpc error` or `volume attachment`, run:

```bash
kubectl delete pod -n miroir-system -l app.kubernetes.io/component=agent --field-selector spec.nodeName=<node>
kubectl get volumeattachment | grep <node>
kubectl delete volumeattachment <name>
```

If the pod is still stuck, stop and ask the user. A reboot goes through `talos-ops`, one node at a
time, after the user says go: `mise run --yes //kube/clusters/artemis/talos:reboot-node <node>`.
Never reboot Frostlink to clear a volume.

### CRD Timing Race (Kustomization fails immediately after new CRDs deployed)

Symptom: resources fail with "no matches for kind X" directly after you add a new app that carries
CRDs.

When the CRDs are established, trigger the reconcile again:

```bash
flux reconcile kustomization <ks-name> -n <namespace>
```

If the cause is dependency order, read `dependsOn` in `ks.yaml`. It must list the CRD provider.

### Image Pull Errors

```bash
kubectl describe pod <pod> -n <namespace> | grep -A3 "Failed"
```

Make sure that the image tag exists in the registry. If the registry rate-limits you, wait, or
read the imagePullSecret.

### HelmRelease Values Not Applying After Git Change

The values reach the HelmRelease through its Kustomization, which reads the `flux-system` artifact.

1. Make sure that the `Push OCI Artifact` run for the commit is green.
2. Run `mise run //kube/clusters/<cluster>:sync-flux ocirepo flux-system`.
3. Reconcile the Kustomization of the app without `--with-source` (Step 3).

## Step 3: Force Reconciliation

Use the Kustomization name from § Kustomization Not Reconciling. Do not add `--with-source` (see the
forbidden list above).

```bash
flux reconcile kustomization <ks-name> -n <namespace>
flux reconcile helmrelease <app> -n <namespace>
```

## Step 4: Verify

```bash
flux get helmrelease <app> -n <namespace>
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>
kubectl logs -n <namespace> deployment/<app> --tail=20
```

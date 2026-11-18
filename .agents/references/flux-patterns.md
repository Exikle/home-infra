# Reference: Flux Patterns — home-infra

## Core Workflow

Test live before you commit, because `main` goes directly to production. The sequence, and the
`suspend-ks`, `resume-ks`, `test-ks` and `land` tasks that run it, are in
`.agents/instructions/commit-style.md` § The sequence and `tooling.md` § mise tasks. This file
does not restate them. Those files win.

These points are specific to how Flux behaves:

- `FluxInstance/flux` generates the root (`flux-system`). A bare `flux suspend` on the root does
  not hold, because flux-operator drops `spec.suspend` on its next reconcile. `suspend-ks` on the
  root pauses the FluxInstance first (`fluxcd.controlplane.io/reconcile=disabled`). `resume-ks`
  unpauses it only after the root is resumed. While the FluxInstance is paused, flux-operator does
  nothing at all. It does no Flux upgrades and no drift correction. Do not leave the root
  suspended.
- `resume-ks` refuses to wake a child while the root is still suspended. Otherwise the child
  reconciles its OLD spec and writes stale values straight back. That once regrew 13 PVCs, and
  `allowVolumeExpansion` made the growth one-way.
- `mise run //kube/clusters/artemis:diff-ks <ns> <ks>` is read-only and safe to run at any time.
  It renders locally and runs `kubectl diff --server-side`, so you see only real drift. For the
  root, it renders through `flux build` against the live root, because flate cannot see the root.
  Exit 0 means no differences. Exit 1 means differences or a failed render. Read the last line to
  tell them apart. The exit code does not.

Other force-sync targets:

```bash
mise run //kube/clusters/artemis:sync-flux hr                   # all HelmReleases
mise run //kube/clusters/artemis:sync-flux ks                   # all Kustomizations
mise run //kube/clusters/artemis:sync-flux es                   # all ExternalSecrets
mise run //kube/clusters/artemis:sync-flux ocirepo flux-system  # the one source that carries the repo
```

Name the resource in `sync-flux ocirepo`. The bare form annotates every OCIRepository in the
cluster (`kubectl get ocirepository -A --no-headers | wc -l`). There is no `GitRepository` to sync.
The Flux source is an OCIRepository that CI builds.
`mise run //kube/clusters/artemis:sync-flux gitrepo` has no live target.

An annotation does not make CI finish faster. If the `Push OCI Artifact` run is not green, the
source resolves the same pre-commit artifact again and reports success. The webhook below usually
moves the artifact by itself, a few seconds after the run finishes. Look at the artifact before you
use `sync-flux`.

## The webhook that makes a merge reconcile — and the port that silently swallows it

Flux polling does not carry a push to the cluster. After the `oci-push` workflow pushes the
artifact, it pings a notification-controller `Receiver`. That ping starts the reconcile. Without
the ping, every merge waits for the 1m poll of source-controller.

notification-controller serves two HTTP servers on two ports. The wrong one accepts everything.

| Service                   | Pod port | What it is                        | `GET /` | `GET /hook/<path>` |
| ------------------------- | -------- | --------------------------------- | ------- | ------------------ |
| `notification-controller` | 9090     | event server (alerts in)          | 400     | 400                |
| `webhook-receiver`        | 9292     | Receiver server, the one you want | 404     | 400                |

The Receiver server is the one you want. The event server answers 400 to every GET and accepts any
POST with a 202. A route that points at the event server looks healthy, but it never starts a
reconcile.

Keep these points in mind:

- The HTTPRoute backend must be `webhook-receiver`, not `notification-controller`.
- The gatus condition is `[STATUS] == 404`. This is the better assertion. Only the Receiver server
  gives a 404 on `/`. The _wrong_ server returns 400.
- A successful hook POST returns HTTP 200, not 202. The ping is the `flux-notify` step of the
  reusable workflow `Exikle/forgejo-workflows/.forgejo/workflows/oci-push.yaml`, not a file in this
  repo. Its accept-list is `200, 202, 429`. It was `202, 429` before. That list matched the
  behaviour of the event server and scored a working webhook as a failure.
- `flux-notify` sets `onError: continue`, so a broken ping never fails the build. This is
  deliberate, because the artifact is already pushed. But the step cannot alert you. Make sure that
  the webhook works by its effect, not by the step.

The only proof that the webhook works is a `lastHandledReconcileAt` that moves without a manual
sync:

```bash
kubectl get ocirepository -n flux-system flux-system \
  -o jsonpath='{.status.lastHandledReconcileAt}'
```

Compare the value with the timestamp of the notify step in the run log. `✔ applied revision` proves
nothing. That message comes from the poll, which works with or without the webhook.

---

## Stuck HelmRelease

Use the mise tasks. They name the cluster in their path. The order is the same as in
`.agents/skills/fix-flux/SKILL.md`:

1. Retry the release: `mise run //kube/clusters/<cluster>:unstick-hr <namespace> <app>`. The task
   forces a one-off install or upgrade and resets the failure count.
2. If the release is still stuck, ask the user. Do not continue without the user's go-ahead.
3. With the go-ahead, run
   `mise run --yes //kube/clusters/<cluster>:reset-hr <namespace> <app>`. The task deletes the Helm
   release history and reinstalls. Rollback to earlier revisions is lost.

Never delete the Helm release Secrets by hand. `reset-hr` is the only route.

## Key Rules

- Set `prune: false` on the `flux-instance` Kustomization. Never prune Flux itself. A few other
  Kustomizations also set it. `grep -rln 'prune: false' kube` lists them.
- `dependsOn` must list the real runtime dependencies, not only the chart sources.
- `interval: 1h` is the standard in `ks.yaml`. `grep -h 'interval:' kube/clusters/artemis/apps/*/*/ks.yaml | sort | uniq -c`
  shows the exceptions.
- The child-defaults patch that the FluxInstance puts on the root injects `retryInterval: 1m`. An
  explicit one in a child is redundant. It does no harm, but do not add it "because it is
  missing". It is not missing.

The live source of truth is `FluxInstance/flux` in `flux-system`. It syncs `kind: OCIRepository`
from `oci://registry.dcunha.io/exikle/artemis`. To read the controller versions, run
`kubectl get deploy -n flux-system -o jsonpath='{range .items[*]}{.metadata.name} {.spec.template.spec.containers[0].image}{"\n"}{end}'`.

## Cross-Namespace Kustomization Gotchas

Kustomizations live in their target namespace (for example `observability` or `media`). They are
NOT always in `flux-system`.

If a `Kustomization` lives outside `flux-system` (for example in `media` or `cortex`), both
references must be explicit:

```yaml
spec:
    sourceRef:
        kind: OCIRepository
        name: flux-system
        namespace: flux-system
    dependsOn:
        - name: miroir
          namespace: miroir-system
```

`sourceRef.namespace` is REQUIRED. If you omit it, it resolves to the namespace of the child, and
Flux does not find the source. The same applies to every cross-namespace `dependsOn` entry. If
either is missing, the reconciliation fails with a silent "not found".

| Field            | Correct         | Wrong                                                                                                                             |
| ---------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `sourceRef.kind` | `OCIRepository` | `GitRepository`. The flux source is OCI. `grep -L 'kind: OCIRepository' kube/clusters/artemis/apps/*/*/ks.yaml` must list nothing |

The only live `kind: GitRepository` in the repo is
`kube/components/alerts/alertmanager/alert.yaml`. There it is a notification `eventSource`
selector. It has no relation to Kustomization sources.

## CRD Timing Race

A Kustomization can deploy a HelmRelease that installs CRDs. It can also deploy resources that
need those CRDs (for example `AlertmanagerConfig` or `Probe`). Flux then applies everything at
once, before Helm runs.

Symptom: The HelmRelease shows healthy, but the expected CRs are missing.

Fix: After the HelmRelease is healthy, force-sync the affected Kustomization:

```bash
mise run //kube/clusters/artemis:sync-flux ks <name>
```

## The root Kustomization overwrites every child's `spec.patches`

The FluxInstance (`kube/base/flux-system/flux-instance/app/helmrelease.yaml`, shared by both
clusters) patches the root `flux-system` Kustomization. The root syncs
`./kube/clusters/<cluster>/apps` directly. The patch is a `patches:` block that targets
`kustomize.toolkit.fluxcd.io/Kustomization` with `metadata.name: _`. That target matches every
child `ks.yaml` in the repo. The patch sets `deletionPolicy`, `retryInterval`, and a nested
`spec.patches`. The nested `spec.patches` applies the HelmRelease install, upgrade, and rollback
defaults.

The patch sets `spec.patches` as a whole. If you write a `patches:` block into the `ks.yaml` of an
app, the root silently replaces it. There is no error and no warning. The patch never applies. The
symptom shows up later as "my override is not taking effect". `flate` does not evaluate the parent
patch either, so a local render looks as though the override worked.

Put per-app kustomize overrides in the `app/kustomization.yaml` of the app. The kustomize build of
the child evaluates `patches:` there, and the parent does not touch it. Do not add `spec.patches`
to a `ks.yaml`.

## kopiur CRs stall `wait: true` health checks

Older kopiur wrote `status.observedGeneration` on a `SnapshotSchedule` at its first reconcile and
never again. After an edit to the spec of the schedule, the object stayed at
`generation != observedGeneration` for good. kstatus reads that as `InProgress`. A Kustomization
with `wait: true` then hung on health checks for the full timeout, in every cycle, with no end.
While it was stuck on a stale revision, it silently applied old configuration again over a change.

On the kopiur version that runs now, every `SnapshotSchedule` shows `observedGeneration` equal to
`generation`, also after edits. Nobody recorded a test that proves the fix. Until one does, keep
the rule below.

- `healthCheckExprs` does not help. Flux evaluates the generation precondition _before_ the CEL
  expressions, so the stale field still wins.
- Fix: Drop `wait: true`, and gate on the HelmRelease through explicit `spec.healthChecks`. That
  is what "the app is up" really means.
- `Restore`: see `kopiur.md`, which wins. Delete and recreate it. Never edit it, and never give it
  an `ssa:` annotation.
- Diagnostic: Run `kubectl get snapshotschedule -A -o json` and compare `.metadata.generation` with
  `.status.observedGeneration`.

## Decode a base64 1Password field per-field, not item-wide

`decodingStrategy: Base64` on a `dataFrom.extract` applies to every field in the item. If only one
field is stored encoded, use `| b64dec` in the target template instead. The `cosign` item of
`flux-webhook` is the live example. `cosign.pub` is base64, but `COSIGN_PASSWORD` next to it is
plain text. An item-wide strategy corrupts it.

## Common Anti-Patterns

The general anti-patterns are in `cluster-conventions.md` § Common Mistakes — Quick Reference,
which wins. The one that is specific to Flux:

- `spec.patches` in the `ks.yaml` of an app. The root Kustomization overwrites it. See above.

## Frostlink

Everything above applies to Frostlink too. Use its own tasks
(`mise run //kube/clusters/frostlink:<task>`) and `--context frostlink` on `kubectl` and `flux`.
This section lists only the differences.

- Source. `FluxInstance/flux` syncs `kind: OCIRepository` from
  `oci://registry.frostlink.dev/exikle/frostlink` at `interval: 1m`. CI builds and pushes it.
  `kubectl get gitrepository -A --context frostlink` returns nothing. So
  `mise run //kube/clusters/frostlink:sync-flux gitrepo` does nothing, but it looks as though it
  worked. Versions: `kubectl get fluxinstance flux -n flux-system --context frostlink -o jsonpath='{.status.components}'`.
- Do not sync before CI rebuilds the artifact. A sync before that resolves the pre-commit artifact
  again and reverts what you landed. To make sure that the artifact carries your commit, use the
  command in `.agents/instructions/commit-style.md` § Frostlink. That file wins. The same rule
  holds during a rebuild (`oci-rebuild.md`).
- `prune: false` is set on a few Kustomizations (`grep -rln 'prune: false' kube/base kube/clusters/frostlink`).
  Everything else prunes. Some infrastructure `ks.yaml` files use `interval: 30m`
  (`grep -rh 'interval:' kube/clusters/frostlink/apps/*/*/ks.yaml | sort | uniq -c`).
  A few children override the injected `retryInterval: 1m` on purpose.
- Root patch. Frostlink uses the same FluxInstance as Artemis,
  `kube/base/flux-system/flux-instance/app/helmrelease.yaml`. Only the sync URL and path come
  from `kube/clusters/frostlink/apps/flux-system/flux-instance/extras/values.yaml`. The
  `spec.patches` rule above applies unchanged.
- kopiur `wait: true` stall. On Frostlink, `fediverse/apoci`, `fediverse/gotosocial` and
  `matrix/continuwuity` dropped `wait: true` and gate on the HelmRelease. `Restore` can stall the
  same way (`openebs-zfs.md` § No `ssa:` annotation). Diagnostic:
  `kubectl get snapshotschedule -A -o json --context frostlink`.
- You cannot test `ks.yaml` changes locally. `apply-ks <ns> <ks>` applies the app path, not the
  Kustomization CR. A running root reverts a patched live CR. A push is the only proven test, so
  plan to make sure of the result after the push.

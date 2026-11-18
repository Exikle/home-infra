---
name: modify-app
description: Change an app that is already deployed — bump or repin an image, edit HelmRelease values, resize or move storage, add or remove a component, change a route, rewire a secret, adjust resources or probes. Then diff it against the live cluster and test-apply before committing. Use for "change X", "update X's config", "bump X", "add persistence to X", "move X behind tinyauth", "give X more memory", "add a backup to X", "edit X's HelmRelease", or "X needs a different port". For a brand-new app use `deploy-app`. For a pure convention lint use `review-app`. Covers Artemis and Frostlink.
---

# Skill: Modify App

Change one app that is already running, without breaking it.

`deploy-app` scaffolds a new app. `review-app` lints the files. This skill is the middle case. The
app exists and works, and you change it while it serves traffic.

Before you edit, read these files:

- `.agents/instructions/cluster-conventions.md` and `.agents/instructions/yaml-conventions.md`.
- `.agents/skills/modules/templates/helmrelease.md` and `templates/ks.md`. They are the same spec
  that `deploy-app` writes against. Read them in full. A partial read gives a partial spec.
- The files for the part that the change touches: `references/storage.md` and
  `references/kopiur.md` (persistence), `references/networking.md` (routes),
  `references/postgres-dragonfly.md` (database or cache), `references/gpu.md` (GPU),
  `references/media-stack.md` (media namespace).

Goal: land one change, and prove that it is the change you meant.

The skill succeeds when three things are true. `mise run //kube/clusters/artemis:diff-ks` shows
only your intended difference. The app is applied live. The user confirmed that it still works.

Stop when you applied the change and asked for confirmation. Never commit before the user confirms.
`main` reconciles straight to production, and there is no staging cluster.

> This skill does not cover these cases: a Renovate image bump (use `triage-renovate`), a stuck
> reconcile (`fix-flux`), a PVC that you must reprovision onto new StorageClass parameters
> (`recreate-pvc`), or data recovery (`kopiur-restore`).

---

## Step 1: Locate what you are changing

The app directory is `kube/clusters/artemis/apps/<namespace>/<app>/`. Two things often waste time
here. The commands below find both:

```bash
# The Kustomization name is metadata.name in ks.yaml — it is NOT always <app>,
# and one ks.yaml may hold several documents (one per sub-directory).
grep -n "^  name:" kube/clusters/artemis/apps/<namespace>/<app>/ks.yaml

# What files exist for this app
find kube/clusters/artemis/apps/<namespace>/<app> -type f | sort
```

Each kind of change lives in one file:

| Changing            | File                                                                     |
| ------------------- | ------------------------------------------------------------------------ |
| Image tag or digest | `app/helmrelease.yaml` → `controllers.<name>.containers.app.image`       |
| Route / hostname    | `app/helmrelease.yaml` → inline under `route.app`, never a separate file |
| Resources, probes   | `app/helmrelease.yaml`                                                   |
| PVC size            | `ks.yaml` → `postBuild.substitute.KOPIUR_CAPACITY`, or the app's own PVC |
| Adding a component  | `ks.yaml` → `components:` and the matching `postBuild.substitute` keys   |
| Secret fields       | `app/helmrelease.yaml` → `externalSecrets.<id>`                          |
| Chart version       | `app/ocirepository.yaml` → `ref.tag` (bare version, no SHA)              |

## Step 2: Capture the live baseline first

Compare the tree with the running object before you edit:

```bash
mise run //kube/clusters/artemis:diff-ks <namespace> <ks-name>
```

Exit 0 means that the tree already matches the cluster. That is a clean start. Exit 1 means that
the tree differs from the cluster before you touched anything. You must find the cause first.
Someone applied uncommitted work, or a reconcile is in progress. Do not add a change on top of a
diff that you cannot explain.

## Step 3: Make sure that the field is not immutable

Some changes cannot be applied in place. If you edit one of these fields, the HelmRelease never
goes Ready. Or the Kustomization reports success while the live object keeps its old value.

| Field                                            | Reality                                                             |
| ------------------------------------------------ | ------------------------------------------------------------------- |
| PVC `storageClassName`                           | Immutable. Use `recreate-pvc`, never an in-place edit               |
| PVC size downward                                | Not supported. Growing is fine                                      |
| `ResourceClaimTemplate` (GPU)                    | Immutable. You must replace it. See `references/gpu.md`             |
| Service `clusterIP`                              | Immutable                                                           |
| StatefulSet selectors and `volumeClaimTemplates` | Immutable. You must recreate the StatefulSet                        |
| `existingClaim` pointed at a new name            | Silently orphans the old PVC and its data, and the app starts empty |

## Step 4: Make the edit, then render offline

```bash
mise run //kube/clusters/artemis:render-ks <namespace> <ks-name>
```

This task needs no cluster. It runs `flate build ks`. It catches schema errors, missing
substitution variables and malformed YAML before anything touches production. Fix every error
here.

If the change added a component, make sure that its substitutions are present too. A component
without its `postBuild.substitute` keys renders with an empty value, and the render does not fail.

## Step 5: Diff against live, and read it

```bash
mise run //kube/clusters/artemis:diff-ks <namespace> <ks-name>
```

Read every line of the output. The diff must contain your change and nothing else. An extra line
is drift that you did not know about, or a side effect that you did not intend. Resolve it before
you apply. This is the purpose of the step. An unexplained line here is the cheapest bug that you
will catch.

## Step 6: Test and commit

Read `.agents/skills/modules/test-and-commit.md` and follow it. Edit in a worktree. Run
`mise run //:wt:new <type>/<slug>` before Step 1, so that every edit lands in the worktree
(`AGENTS.md` rule 7).

If anything fails, read `.agents/skills/modules/common-issues.md`.

---

## Frostlink

The steps are the same. Change the paths and the commands. Read `.agents/instructions/frostlink.md`
first. It wins where it differs from the shared conventions.

- The app directory is `kube/clusters/frostlink/apps/<namespace>/<app>/`. Replace
  `kube/clusters/artemis/` with `kube/clusters/frostlink/` in every path above.
- Run the tasks as `mise run //kube/clusters/frostlink:diff-ks`, `:render-ks` and `:test-ks`.
- Read the live cluster with `kubectl ... --context frostlink`. Never use the MCP k8s tools. They
  point at Artemis only, so they report the wrong cluster (`AGENTS.md` rule 2).
- Routes use `external-gateway` only. The storage class is `openebs-zfs`, not `miroir`. For a
  persistence change, read `.agents/references/openebs-zfs.md` instead of `storage.md`.
- It is one node. A change that restarts a core pod (Cilium, CoreDNS, the Envoy front door) is an
  outage of every public site. Test it with the user watching
  (`.agents/instructions/commit-style.md` § Frostlink).

## Gotchas

- The ks name is not always the app name. If you run `apply-ks` against the wrong name, it applies
  the manifests of a different app. Always grep `ks.yaml` first (Step 1).
- Never add `spec.patches` to the `ks.yaml` of an app. The root Kustomization sets `spec.patches`
  as a whole, so it overwrites the block of a child. `flate` still renders as though it worked,
  and every offline check passes. No validation catches this change. Put per-app kustomize
  overrides in `app/kustomization.yaml` instead. See `references/flux-patterns.md` § The root
  Kustomization overwrites every child's `spec.patches`.
- Back up the data and get the user's go-ahead before you remove a component. When the ks has
  `prune: true`, Flux deletes what the component created. Almost every ks has it. If you drop
  `components/kopiur/backup`, Flux deletes the `SnapshotPolicy`, the `SnapshotSchedule` and the
  PVC. Deleting the PVC deletes the data of the app.
- A change to the gateway of a route changes who can reach the app. Use exactly one of
  `internal-gateway` (LAN only) or `edge-gateway` (public). If you attach to both, you publish the
  app. `external-gateway` is legacy and takes no new routes. If you move a `*.dcunha.io` route to
  `edge-gateway`, you must also change any `sectionName: https` to `https-dcunha`
  (`towonel-agent.md` § Which gateway a route uses).
- `✔ applied revision` proves nothing about your field. Make sure that the live object carries the
  value that you set. A stale artifact or a reconcile in progress can report success on the old
  tree.

## Not covered by this skill

A clean pass here means that the change renders, diffs as intended, and applies. It does not mean
that the app is correct. This skill does not check these things:

- The preconditions of a component against the real pod.
- Whether the database auth can work.
- Whether your resource numbers match the observed usage.
- What an auth gate breaks for machine-to-machine callers.

For those, spawn the `audit-app` subagent.

---
name: deploy-app
description: Deploy a new app into the Flux cluster end to end — scaffold the ks.yaml and app/ manifests, wire the OCIRepository, HelmRelease, routes, storage, and any ExternalSecret, then test-apply before committing. Use for "deploy X", "add app X", "set up X in namespace Y", "create a new app", or "onboard X to the cluster". Covers Artemis and Frostlink.
---

# Skill: Deploy App

This skill deploys a new application to home-infra with the canonical GitOps workflow.

`<cluster>` in every path and task below is `artemis` or `frostlink`. For Frostlink, read
`.agents/instructions/frostlink.md` as well as the two convention files below. `frostlink.md` wins
where they differ. Read `.agents/references/oci-networking.md` and
`.agents/references/openebs-zfs.md` in place of `networking.md` and `storage.md`. The differences:

- The only gateway is `external-gateway`, with a hostname like `myapp.frostlink.dev`. An HTTPRoute
  on it gets its DNS record automatically, so you do not need a `DNSEndpoint`.
- Persistence uses the `openebs-zfs` StorageClass.
- A new namespace gets `components/alerts` in its `kustomization.yaml`.
  `kube/clusters/frostlink/apps/network/` is a good model. Add no PodSecurity labels, because the
  namespace inherits `baseline`. A privileged namespace needs the justification in
  `.agents/references/towonel.md` § Why its own namespace.
- Adapt kubesearch results with `.agents/instructions/frostlink.md` as well as the shared
  conventions.

Before you write any files, read these files:

- `.agents/instructions/cluster-conventions.md`
- `.agents/instructions/yaml-conventions.md`
- `.agents/references/flux-patterns.md`
- `.agents/references/networking.md` (if the app needs a route)
- `.agents/references/storage.md` (if the app needs persistence) and `.agents/references/kopiur.md`
  (if it needs backups)
- `.agents/references/postgres-dragonfly.md`. You must read it if the app needs Postgres, Redis,
  or any cache. The policy is in `cluster-conventions.md` § Deployment Philosophy (Artemis), which
  wins.
- `.agents/references/media-stack.md` (if you deploy into the `media` namespace)

---

> Read these module files in full. `deploy-app` and `review-app` share them deliberately. One
> skill writes the files, and the other checks them against the same spec. A duplicate lets
> the two drift apart. A partial read gives a partial spec.

Goal: scaffold one new app and prove that it renders. Then hand it to the user to confirm live.

Success has three parts:

1. `mise run //kube/clusters/<cluster>:render-ks <ns> <ks-name>` succeeds.
2. `mise run //kube/clusters/<cluster>:test-ks <ns> <ks-name>` suspends the root and the target
   and applies cleanly.
3. The user confirmed that the app works.

Edit in a worktree. Run `mise run //:wt:new feat/<slug>` first (`AGENTS.md` rule 7).

Stop when the app is applied and you asked for confirmation. Do not commit before the user
confirms. This repo reconciles `main` straight to production, with no staging. The sequence,
including when it is safe to resume, is in `.agents/instructions/commit-style.md` § The sequence.

## Step 1: Gather Requirements

Make sure that you have these before you continue:

- App name (for example `myapp`)
- Namespace. It must exist, or the user confirms that you create it.
- Chart. The default is app-template (the current tag: `templates/ocirepository.md` § Values that
  drift). If it is different, ask.
- Route: LAN-only (`internal-gateway`), public (`edge-gateway`, `*.dcunha.io` or
  `*.frostlink.dev` through towonel), or none. On Artemis, do not use `external-gateway`. It is
  legacy and takes no routes. An app can carry a second route for a second hostname.
- Hostname (for example `myapp.dcunha.io`)
- Persistence. Does the app need a PVC? If yes, get the size (for example `5Gi`), and ask whether
  to use kopiur backup.
- Secrets. Does the app need a 1Password ExternalSecret? If yes, get the name of the 1Password
  item.

Before you write anything, read one or two existing apps in the same namespace to match the local
patterns:

```bash
ls kube/clusters/<cluster>/apps/<namespace>/
cat kube/clusters/<cluster>/apps/<namespace>/<existing-app>/ks.yaml
cat kube/clusters/<cluster>/apps/<namespace>/<existing-app>/app/helmrelease.yaml
```

---

## Step 2: Find a Reference with Kubesearch

Invoke the `kubesearch` skill for the app name. Use the top result to fill in the remaining
unknowns:

| What                   | Where it goes                                |
| ---------------------- | -------------------------------------------- |
| Image repository + tag | Step 3 (image pinning)                       |
| Container port         | `service.app.ports.http.port` in helmrelease |
| Mount paths            | `persistence` block in helmrelease           |
| App-specific env vars  | `containers.app.env` in helmrelease          |
| Secret env var names   | `values.externalSecrets` template fields     |

Adapt the patterns from the reference to the home-infra conventions that the kubesearch skill
documents:

1. Remove TZ.
2. Replace HelmRepository with OCIRepository.
3. Replace Ingress with HTTPRoute.
4. Move any MariaDB, Redis or per-app Postgres dependencies onto the shared `database` namespace.

If kubesearch returns no results, use the GitHub search in the kubesearch skill instead. Continue
with what you find.

---

## Step 3: Pin the Image Tag

Use the image repository that you found in Step 2. Read `.agents/skills/modules/image-pinning.md`
and follow it.

---

## Step 4: Create Directory Structure

Read `.agents/skills/modules/templates/directory.md` and create the layout.

If the namespace does not exist yet, create it first:

```
kube/clusters/<cluster>/apps/<namespace>/
├── namespace.yaml
└── kustomization.yaml
```

For `namespace.yaml` on Artemis, use `name: _`. Kustomize rewrites it from the `namespace:` field:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/core/namespace_v1.json
apiVersion: v1
kind: Namespace
metadata:
    name: _
    annotations:
        kustomize.toolkit.fluxcd.io/prune: disabled
    labels:
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/warn: privileged
```

`kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <namespace>

components:
    - ../../../../components/alerts

resources:
    - ./namespace.yaml
    - ./<app>/ks.yaml
```

On Artemis, add two more entries under `components` when an app in the namespace needs them:

- `- ../../components/kopiur/secret` when an app uses `kopiur/backup`.
- `- ../../components/postgres/tenants` when an app uses `postgres/app`.

Flux discovers the new namespace directory automatically. No other wiring is necessary.

---

## Step 5: Write Files

For each file, read the matching template module and write the file:

| File                     | Template module                                                               |
| ------------------------ | ----------------------------------------------------------------------------- |
| `ks.yaml`                | `.agents/skills/modules/templates/ks.md`                                      |
| `app/kustomization.yaml` | `.agents/skills/modules/templates/kustomization.md`                           |
| `app/ocirepository.yaml` | `.agents/skills/modules/templates/ocirepository.md`                           |
| `app/helmrelease.yaml`   | `.agents/skills/modules/templates/helmrelease.md`                             |
| inline `externalSecrets` | `.agents/skills/modules/templates/externalsecret.md` (only if secrets needed) |

All YAML must follow `.agents/instructions/yaml-conventions.md`.

---

## Step 6: Add to Namespace Kustomization

Add `- ./<app>/ks.yaml` to the resources in
`kube/clusters/<cluster>/apps/<namespace>/kustomization.yaml`, in alphabetical position.

---

## Step 7: Verify Files

1. Make sure that all expected files are present:

    ```bash
    find kube/clusters/<cluster>/apps/<namespace>/<app> -type f | sort
    ```

2. Before you apply, make sure that the kustomization renders cleanly with flate:

    ```bash
    mise run //kube/clusters/<cluster>:render-ks <namespace> <ks-name>
    ```

This runs `flate build ks`. It finds schema errors, missing substitution variables and malformed
YAML before anything touches the cluster. If it reports errors, fix them before you go to Step 8.

---

## Step 8: Test and Commit

Read `.agents/skills/modules/test-and-commit.md` and follow it.

If anything fails, read `.agents/skills/modules/common-issues.md` for diagnostics.

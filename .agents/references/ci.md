# CI — home-infra

This file explains how Forgejo Actions runs here. It covers the `oci-push` workflow that builds
the Flux artifacts of this repo, the container builds for `Exikle/containers`, the runner that they
all share, and the reasons behind each. Manifests under `kube/clusters/*/` carry no comments
(`yaml-conventions.md` § No Comments in Manifests), so the reasons live here.

Tekton (`tekton-system`, `forgejo/tekton-runner`) was retired on 2026-10-27. Every workflow now runs
on the plain `forgejo-runner`. Do not bring Tekton back to work around a runner limit. Fix the
runner.

---

## Where the workflows live

| Piece                               | Where                                                                    |
| ----------------------------------- | ------------------------------------------------------------------------ |
| The jobs themselves                 | `Exikle/forgejo-workflows`, `.forgejo/workflows/*.yaml` (reusable)       |
| The callers (triggers, concurrency) | each repo's `.forgejo/workflows/`, pinned to a forgejo-workflows commit  |
| The job image                       | `ci-toolbox` in `Exikle/containers` (`apps/ci-toolbox/`)                 |
| The runner, its labels and podspecs | `kube/clusters/artemis/apps/forgejo/forgejo-runner/app/helmrelease.yaml` |
| The remote image builder            | `kube/clusters/artemis/apps/forgejo/buildkit/`                           |

A change to a shared workflow reaches a repo only when the pin of that repo moves. A pin is a
commit sha. Renovate moves pins through the `forgejo-workflows` manager in `exikle/renovate-config`.
To test a change before it is on `main`, do these steps:

1. Push the change to a branch of `forgejo-workflows`.
2. On a test branch of the caller repo, point the caller at that commit.

Test `oci-push` against scratch repositories, never the real ones. A test caller passes its own
`forgejo-oci-url` and `registry-oci-url` (for example `…/exikle/ci-plain-runner-test`). Do not run
against the real URLs from a branch. The run moves the `main` tag onto a branch commit, and Flux
deploys it.

---

## The runner

`forgejo-runner` is the upstream Forgejo runner. The k8s plugin of Erwan Leboucher runs beside it
as a native sidecar. Every job is its own pod in `forgejo`. The pod is built from the podspec that
the label of the job names.

| Label                                      | Podspec            | Use                                                        |
| ------------------------------------------ | ------------------ | ---------------------------------------------------------- |
| `ubuntu-latest`, `ubuntu-24.04`, `default` | `podspec-default`  | Everything that needs no special mounts                    |
| `buildkit`                                 | `podspec-buildkit` | Image builds. It mounts the buildkitd client cert          |
| `docker`, `multiarch`                      | `podspec-dind`     | A privileged dind sidecar, for workflows that need dockerd |
| `talos`                                    | `podspec-talos`    | talosctl jobs. It mounts a Talos API service account       |

Keep the runner and the plugin on the same major version. The plugin protocol changed between 12.x
and 13.x, and a mismatched pair does not run jobs. Renovate does not group the two images. So when
one of them gets a major bump, hold it until the other one has the same major.

The plugin has these behaviours, which the chart does not make clear:

- `container:` in a workflow replaces the main image of the podspec. It keeps everything else:
  volumes, mounts, env, and resources. That is how `buildkit` jobs run `ci-toolbox` and still get
  `/buildkit-certs`. The image must have `sh`, because the main command of the plugin is
  `sh -c 'mkdir … && sleep'`.
- Job pods carry the label `app.kubernetes.io/managed-by: forgejo-runner`. The plugin ignores pod
  labels that you set in a podspec. Select job pods by that label. The NetworkPolicy of buildkit
  does this.
- The actions cache works from job pods. `actions/cache` and `cache: true` of `jdx/mise-action`
  connect to the cache server of the runner on 8088/8089. The cache lives on the `/data` emptyDir
  of the runner pod, so a runner restart empties it. The first run after a rollout is always a
  miss.
- The memory limit of the plugin sidecar is raised to 512Mi. Upstream reports that the 128Mi of the
  chart runs out of memory at capacity 3. This runner runs at a higher capacity. To read it, run
  `grep capacity: kube/clusters/artemis/apps/forgejo/forgejo-runner/app/helmrelease.yaml`.

---

## The two clocks, now only one

A change to a shared workflow has two halves. One half is the pin of the caller, which Forgejo reads
from git on each run. The other half is the shared workflow at that pin. Both halves are in git.
There is no cluster half. If a change to a shared workflow breaks `oci-push`, revert the pin of
the caller. Nothing in the cluster has to change first.

The runner labels are the one cluster dependency that is left. If a workflow asks for a label that
the runner does not offer, the job waits in the queue forever and reports nothing. Before you land
a workflow that uses a new label, do these steps:

1. Add the label and its podspec to the runner.
2. Make sure that the label exists with `fjo api /admin/actions/runners`.

---

## `oci-push`

The caller in this repo (`.forgejo/workflows/oci-push.yaml`) first runs a `changes` job. That job
picks the clusters that the push reaches (`commit-style.md` § Frostlink). Then it runs one job per
picked cluster. Each of these jobs calls the shared `oci-push` workflow, which is one job with one
step. It runs on `ubuntu-latest` with the `ci-toolbox` image. The step does this:

1. It shallow-clones the commit. The `path` input names the folder that becomes the artifact
   root, and `ignore-paths` names what to leave out. This repo passes `path: .` and an ignore
   list per cluster. So each artifact holds `kube/base/`, `kube/components/` and the Flux folders
   of one cluster. It does not hold the other cluster, `talos/` or `bootstrap/`.
2. In the background, it releases to the Forgejo mirror (`oci://git.dcunha.io/exikle/<cluster>`).
3. In the foreground, it releases to the standalone registry of the cluster
   (`registry.dcunha.io` for Artemis, `registry.frostlink.dev` for Frostlink). Then it sends a
   ping to Flux.
4. It waits for the mirror. If the mirror release failed, the run fails.

"Release" is `flux push artifact` → `flux tag artifact --tag main` → `cosign sign` → `cosign verify`.
The job tries each part up to 3 times. Flux reads only the standalone registry. So the webhook
fires as soon as that copy passes verification, about 20s after the job starts. It does not wait
for the mirror.

Keep the mirror. Each standalone registry is apoci (`fediverse/apoci`), which runs inside its own
cluster. So Flux bootstraps a cluster from a registry that the cluster hosts. The Forgejo copy on
LXC 105 is the only artifact that survives when the cluster is down.

A missed webhook ping never fails the run. Flux finds the artifact on its next poll. The Frostlink
receiver has a grey DNS record that points at the node, and CrowdSec exempts the
`flux-webhook.frostlink.dev` host from the bot challenge (`crowdsec.md` § What is never
challenged).

The workflow has one step, not five, because each extra step costs time (§ Workflow shape — what
costs time).

---

## `render` — the clusters that a change under `kube/` reaches

`.forgejo/workflows/render.yaml` runs in three cases:

- On each push to `main` that changes `kube/**`.
- On each pull request, whatever it changes.
- By hand (`workflow_dispatch`).

First, a `changes` job picks the clusters with the same rule as `oci-push.yaml`. A change under
`kube/base/` or `kube/components/` reaches both clusters. A change under
`kube/clusters/<cluster>/apps/` or `components/` reaches only that cluster. A manual run renders
both. For a pull request, the job reads the file list of the PR from the API. The
`pull_request.base.sha` of the event is `main` at the time that the PR opened. It is not the merge
base. So a diff against it also holds everything that merged since then.

Then one job per picked cluster runs on the default runner image. The job installs `flate` with
`mise-action` from the shared mise-config pin. Then it runs
`flate build all --path kube/clusters/<cluster>` with `FLATE_ALLOW_MISSING_KINDS=Secret` and
`FLATE_DISABLE_CHART_DIGEST_TRACKING=true`. If the render breaks, the job fails. A cluster that the
change does not reach gets no render job. If the change reaches no cluster, one placeholder job,
`Render none`, runs and skips all its steps. Forgejo creates no job at all from an empty matrix,
and a job that `needs` it then stays `blocked` forever (seen on #3456).

A last job, `Result`, always runs. It passes when the `changes` job passed and every render job
passed or was skipped. Branch protection on `main` requires its status,
`Render Clusters / Result (pull_request)`, beside `Kritika / Review`. The per-cluster render
checks cannot be required, because a PR that does not reach a cluster never gets that check, and
Forgejo then waits for it forever. That is also why the workflow runs on every pull request: a PR
outside `kube/` still needs a `Result` status.

This gate matters because `platformAutomerge` is on. Forgejo merges an armed Renovate PR as soon as
the required checks pass. Before the gate, only Kritika was required, so PRs merged while the
render still ran (#3441 on 2026-11-22).

The render reads the git checkout, not the artifact. flate resolves every `spec.path` from the repo
root, so this view equals what Flux gets. `FLATE_ALLOW_MISSING_KINDS=Secret` lets the render go on
when a Secret exists only in the live cluster, such as one that 1Password creates. The render
still applies the per-cluster `valuesFrom` ConfigMaps (`app-structure.md` § Per-cluster values).

---

## Signing is load-bearing

The OCIRepository of `flux-system` sets `verify.provider: cosign` with
`secretRef: cosign-public-key`. Flux rejects an artifact that it cannot verify. So a broken signing
key stops reconciliation in the whole cluster.

- If you push a manual recovery artifact, copy the `path` and `ignore-paths` of the job of that
  cluster in `.forgejo/workflows/oci-push.yaml` exactly
  (`flux push artifact oci://…/<cluster>:<sha> --path=. --ignore-paths='<that list>' …`). Without
  them, the artifact holds the whole repo, `terraform/` included. Then sign it:
  `flux tag artifact --tag main` →
  `cosign sign --yes --tlog-upload=false --use-signing-config=false --key …`. The key is the
  `cosign` item in the `artemis` 1Password vault.
- Signing is offline. Nothing goes to the public Rekor log. cosign v3 rejects
  `--tlog-upload=false` alone, because it conflicts with the default `--use-signing-config`. So you
  need both flags. Every `cosign verify` here passes `--insecure-ignore-tlog`.

`oci-push` pins the public key that Flux trusts in the workflow itself. It does not derive the key
from the private key. So if a run signs with the wrong key, it fails in CI, not without a sign at
reconcile time.

Two keys stay apart:

- The `cosign` key, which Flux trusts. Only this key can sign a cluster artifact. So it is a repo
  secret on `home-infra` alone, and the jobs of both clusters use it.
- The `cosign-release` key, which signs `containers` images. It is in the account-level
  `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` secrets. The workflows of every repo can read them.

A repo secret overrides an account secret of the same name. That is what makes the split work.
Never set the Flux key at account level.

Secrets are job env. Every step of a job sees the secrets of the job. This is one more reason why
each workflow is a single step that only its own repo can change.

---

## Container builds — `container-release` and `container-pull-request`

Both workflows run on the `buildkit` label with the `ci-toolbox` image. They connect to buildkitd
over mTLS with `docker buildx --driver remote`. No dockerd takes part.

- The job reads the app version directly from the HCL (the default of `variable "VERSION"`). It
  does not use `buildx bake --print`. So reading the version never depends on buildkitd. The tag
  ladder is the same as in the app-versions action: an optional `v`, then one to three numeric
  parts.
- Tags go in through a bake override file, not through `--set`. `--set` takes a single reference.
  It reads a comma-joined list as one tag that is not valid. The HCL declares an empty
  `docker-metadata-action` target for `image` to inherit.
- Bake `image-all`, never `image`. `image-all` carries the platform list. `image` alone builds only
  the native platform of the builder. One bake run pushes a single index to both registries. So
  both registries get the same digest, and there is nothing to merge.
- A pull request publishes nothing (`output=type=cacheonly`, `cache-to=type=inline`). It cannot
  write to either registry. It cannot poison the cache that the release path reads back.
- The weekly rebuild runs `--no-cache --pull`. Base images sit on tags that change, and a cached
  build replays old `apk add` layers. The rebuild still exports the registry cache.
- Signing covers only the index digest, on both registries. Nothing verifies per-platform digests.
  So `--recursive` adds signatures that nobody reads.
- Lint runs on the default image, not on `ci-toolbox`, because zizmor has no musl build. Tools come
  from `.mise/config.toml` through `mise-action` with its cache. These are the same pins as
  `mise run lint`.

Validation and release share one buildkitd on purpose. This includes its `RUN --mount=type=cache`
mounts, which `cacheonly` does not isolate. Pull requests on `containers` come only from the owner
and from Renovate. If the repo starts to take pull requests from other people, look at this again.

---

## buildkit — the remote builder, and why its security context is loose

### Two boundaries, not one

Two things guard port 1234: mTLS, and the NetworkPolicy inline in `buildkit/app/helmrelease.yaml`
(`networkpolicies:`). Keep both. Neither one replaces the other.

- mTLS: `--tlscacert` makes a client certificate mandatory. `internal-ca-issuer` issues both certs.
  The SAN of the server cert is `buildkit.forgejo.svc.cluster.local`. A job must dial that name,
  or the handshake fails on hostname verification. The client cert reaches jobs only through the
  podspec of the `buildkit` runner label. That podspec mounts the `buildkit-client-cert` Secret at
  `/buildkit-certs`.
- NetworkPolicy: Ingress to 1234 is allowed only from pods in `forgejo` that carry the label
  `app.kubernetes.io/managed-by: forgejo-runner`. The k8s plugin puts that label on every job pod.

The label was never a credential. Anything that can create a pod in `forgejo` can carry it. The
client cert closes that gap. `usages` keeps the two certs apart. The server cert has only
`server auth`, and the client cert has only `client auth`. One risk remains. Any other cert from
that CA with a clientAuth EKU also authenticates. To mint one, you need RBAC to create a
`Certificate`. That is a much higher bar than to create a pod in `forgejo`, so the team accepted
the risk.

> Not closed by any of this: the Role `forgejo-runner` (from the chart, not from git) carries
> `pods/exec: create` on every pod in `forgejo`, `buildkit-0` included. An exec goes around the
> NetworkPolicy and the TLS listener.

### Settings that look wrong but are not

| Setting                                                                                                              | Why                                                                                                                                                                                                                                                            |
| -------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `container.apparmor.security.beta.kubernetes.io/buildkitd: unconfined` (annotation, not the `appArmorProfile` field) | Rootless buildkitd unshares user namespaces. The default AppArmor profile denies that. app-template rejects the `appArmorProfile` securityContext field, so the annotation is the only route.                                                                  |
| `--oci-worker-no-process-sandbox`                                                                                    | Rootless without `privileged` must skip the process sandbox. The pod itself is the isolation boundary.                                                                                                                                                         |
| `allowPrivilegeEscalation: true`, `capabilities.add: [SETUID, SETGID]`                                               | rootlesskit maps UIDs through `newuidmap`/`newgidmap`, which are setuid binaries. If you set `allowPrivilegeEscalation: false`, the kernel denies the exec. If you drop SETUID/SETGID from the bounding set, the kernel cannot honour their file capabilities. |
| `readOnlyRootFilesystem: false`                                                                                      | buildkitd writes worker state and snapshots to the root filesystem.                                                                                                                                                                                            |
| liveness/readiness `buildctl --addr unix:///run/user/1000/buildkitd.sock debug workers`                              | `--addr` is repeatable. buildkitd serves a unix socket beside the TCP listener only so that the probe has an address it can reach. A probe on `tcp://localhost:1234` needs a client cert, because TLS applies there.                                           |

---

## Workflow shape — what costs time

These numbers were measured on this runner on 2026-10-15 and 2026-10-27. Issue #2807 has the
original test harness.

| Cost                                   | Plain runner (k8s plugin) |
| -------------------------------------- | ------------------------- |
| Pod start-up per job                   | ~6-10s (image cached)     |
| Each extra step in a job               | ~4s                       |
| Each extra job (chained with `needs:`) | +12-15s                   |

- Cut jobs first, then steps. A job is a pod. Split work into jobs only when each part does more
  than ~15s of real work in parallel.
- Put tools into the job image. Do not install them at run time. `ci-toolbox` carries git, jq, yq,
  python3, curl, flux, cosign, docker and buildx. `apk add` costs ~5s a job, and a download from
  GitHub can fail.
- Shared logic for small jobs lives in `ci-toolbox` (`run: ci <command>`). You can test it locally
  with `podman run … ci <command> --dry-run`.
- The vulnerability scan is one job for every app. The grype database is a download of ~4 minutes,
  and a matrix fetched it once per app.

---

## Multi-arch builds (linux/amd64 + linux/arm64)

Every app in `Exikle/containers` builds for both architectures. So its image runs on Artemis
(amd64) and on Frostlink (arm64). The build never emulates the target architecture, because it
cannot here:

- The Talos kernel has no `binfmt_misc` at all (not a module, not built in). So no node can
  register QEMU user-mode emulation. `buildkit` offers only `linux/amd64` and `linux/386`.
- `kata-qemu` pods fail with `Unsupported network interface: netkit`. Cilium runs the netkit
  datapath, and Kata does not support it.

So each Dockerfile does all of its work on `$BUILDPLATFORM`. It only assembles the target
architecture:

- Go: Cross-compile with `GOOS="${TARGETOS}" GOARCH="${TARGETARCH}"` and `CGO_ENABLED=0`. If the
  app needs cgo, use `xx-go`.
- Static binaries from upstream images: `COPY --from=<image@digest>` in the final stage picks the
  variant for the target platform and runs nothing. `ci-toolbox` gets flux, cosign, docker and
  buildx this way.
- The runtime filesystem: From an amd64 container, install the alpine packages of the target
  architecture into an empty root. Then `COPY` that root into `FROM scratch`.
  `apps/ci-toolbox/Dockerfile` is the reference shape. It handles three things that are not
  obvious:
    - An amd64 alpine image trusts only amd64 index signatures. Install `alpine-keys`, and copy
      `/usr/share/apk/keys/<arch>/*.pub` into the new root. If you do not, apk rejects the index
      as UNTRUSTED.
    - It uses `--no-scripts`, because package post-install scripts are target-arch binaries.
    - The busybox applet symlinks usually come from such a script. The Dockerfile makes them again
      from `busybox --list-full` of the build-arch busybox. The applet list is the same.
- Never `RUN` a target-arch binary in a Dockerfile. If an app ever needs that, it needs a native
  arm64 builder, not emulation. Frostlink is the only arm64 machine.

To add arm64 to an app, do these steps:

1. Add `"linux/arm64"` to `image-all` in the `docker-bake.hcl` of the app.
2. Change the final stage to the rootfs shape.
3. Test it locally with
   `podman build --platform linux/arm64 --ignorefile include/.dockerignore apps/<app>`.

Anything that the image needs at build time must be under `scripts/`, `defaults/` or
`entrypoint.sh`. The shared `.dockerignore` excludes everything else.

## Known ceiling: Multus

Cluster-wide `FailedCreatePodSandBox` retries take most of the run time. Each retry costs ~17–21s.
A single unlucky pod can lose more time than every optimization above saves. The team tested two
likely fixes, and both were wrong. Issue #1956 has the evidence and the lead that is left. Read
that issue before you form a new theory.

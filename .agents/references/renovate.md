# Renovate — Preset Pinning, Automerge Policy, Per-App Guards

The Renovate rules live in three places. `.renovaterc.json5` at the repo root has no prose on
purpose. Every "why" below was once a comment block in that file.

| Layer          | Where                                      | What it holds                                                                                                                                       |
| -------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shared default | `default.json` in `exikle/renovate-config` | The policy that every repo on git.dcunha.io shares                                                                                                  |
| Cluster preset | `cluster.json` in `exikle/renovate-config` | The rules that only Artemis and Frostlink share                                                                                                     |
| This repo      | `.renovaterc.json5`                        | The schedule, the PR body, the manager scopes, and the Frostlink rules scoped to `kube/clusters/frostlink/**`. Its `packageRules` come last and win |

The shared presets are at <https://git.dcunha.io/exikle/renovate-config>. Read `default.json` and
`cluster.json` there for the rules themselves. This doc does not restate them. If the doc and the
preset disagree, the preset wins. The upstream base is
<https://github.com/home-operations/renovate-presets>.

A change to the shared preset reaches every repo on its next Renovate run. It is not an
Artemis-only edit. Before you push it, validate it with `renovate-config-validator` in the preset
repo.

---

## Preset Pinning

```json5
extends: ["local>exikle/renovate-config", "local>exikle/renovate-config:cluster"],
```

This repo pins no upstream preset itself. The pins live in the shared preset:

- The `renovate-presets` base pin, in `default.json`.
- Every `apps/` preset pin, in `cluster.json`.

Bump them in the shared preset.

### Why every entry carries an explicit tag

Up to and including 6.0.0, `default.json` reached its content through nested
`github>home-operations/renovate-presets//config/...` references. These references carried no tag.
Renovate resolves an untagged nested preset against the default branch of the preset repo. It
does not use the tag at which the parent was pinned. So the pin was never real.

Upstream then deleted `config/`, `managers/`, `overrides/` and `policies/` from `main`
(7.0.0, _"consolidate the general-purpose presets into default.json"_). After that, every consumer
pinned to an older tag got a 404 on the nested fetch. Renovate stopped in the init phase, and no
dependency updates ran at all.

7.0.0 is the first release whose files are self-contained. Before you bump the
`renovate-presets` pin to a new tag, make sure that the target tag has no self-references. This
applies to the base pin in `default.json` and to the `apps/` pins in `cluster.json`.

```bash
curl -sf "https://api.github.com/repos/home-operations/renovate-presets/git/trees/<TAG>?recursive=1" \
  | jq -r '.tree[]|select(.type=="blob")|.path'
# then, for default.json and each apps/*.json5 this repo extends:
curl -sf "https://raw.githubusercontent.com/home-operations/renovate-presets/<TAG>/default.json" \
  | grep -n "home-operations/renovate-presets" || echo "self-contained"
```

A silent stop looks the same as "no updates were due". Read the Renovate log, not the PR list.

### Why the apps/ presets are listed individually

6.0.0 made the `apps/` presets opt-in. The root preset no longer pulls them in. So the shared
preset must list every app-specific manager or datasource that this repo depends on. If you drop
one, nothing tells you. The custom manager stops extracting, and the dependency goes stale with no
error. The list is the `extends` of `cluster.json` in `exikle/renovate-config`.

### 7.0.0 ➔ 8.0.0 — the helm-values narrowing

The whole diff is one change in `default.json`. The scope of the `helm-values` manager narrows.
It was the broad `/\.ya?ml(?:\.j2)?$/` glob. Now it is only `values.yaml`, `helmrelease.yaml` and
`hr.yaml`, plus their `.yml` and `.j2` variants.

Upstream gives this reason. The `kubernetes` manager also extracted bare `image:` lines, so each
one was counted twice. That inflated the grouped-update counts against `minimumGroupSize`.

The change has no effect here only because every HelmRelease in this repo is named
`helmrelease.yaml`. The `kubernetes` manager still uses the old broad glob, so it covers
everything that helm-values gave up. If someone adds a HelmRelease under a different file name,
its `spec.values.image.*` block stops being extracted, with no error.

---

## Commit Signing — Model A

`automergeType: "pr"` and `automergeStrategy: "squash"` come from the shared default, not from this
repo.

Renovate squash-merges so that Forgejo creates one merge commit. Forgejo can sign that commit with
the instance SSH key (`MERGES=always`). There is no `platformCommit` and no local GPG signing. The
instance is the only signer for bot commits.

For this reason, no rule here sets `automergeType: "branch"`. That setting pushes the bump directly
to `main`. It skips the PR-and-squash path that lets the instance sign. Unsigned bot commits then
land on a protected branch. The shared `automergeType: "pr"` keeps everything on the signed path.

---

## Per-App Guards

These guards override the broad automerge rules above them. Later `packageRules` win, so the order
is important.

### Cilium — a bump restarts Multus on every node

The `cilium` group in `cluster.json` never automerges, on both clusters. This section gives the
reason. A Cilium upgrade that changes the `cniVersion` of its CNI conflist restarts every `multus`
pod. The pods exit with 0 / Completed, then come back clean.

The cause is upstream, not our configuration:

1. We do not pass `--cni-version`. So multus takes the version of the master plugin on the first
   pass and keeps it in process memory.
2. Cilium 1.20.1 raised its conflist from `0.3.1` to `1.0.0`.
3. The configuration watcher of multus compared the new version against the stale one. It stopped
   with a hard error:
   `Multus cni version is "0.3.1" while master plugin cni version is "1.0.0"`.
4. One restart corrects it.

This is why the effect matters. `00-multus.conflist` is the first CNI configuration on every node.
Multus is in the ADD path for every pod, with a NAD or without one. During the gap, pod creation
fails across the whole cluster. Expect this on any Cilium bump that moves the CNI spec version.
Merge it only while you watch the nodes.

### Talos — never automerge

The rule itself lives in `cluster.json`, and so does the rule for the Kubernetes group. This
section gives the reason.

A merged Talos bump makes tuppr drain and roll every node. So it is never unattended, for a
stable release and for a prerelease. The team first wrote the guard while the cluster ran
v1.14.0-rc.2 (2026-08-26). When `currentValue` is unstable, Renovate follows the prerelease
stream. `factory.talos.dev/versions` lists betas and RCs. So without the guard, an `rc.3` merges itself.
The cluster is back on a stable release (`grep '^talos' .mise/config.toml`), and the guard stays.

The guard is not scoped to `matchDatasources`, on purpose. The Talos version is pinned in two
places. Both resolve to the same `packageName` through different datasources:

- The installer image in `kube/clusters/artemis/talos/*.j2` → `custom.talos-factory`
- The `talos` CLI in `.mise/config.toml` → `github-tags`, through the mise manager

A datasource filter covers only the first one. With such a filter, the CLI automerges on the patch
and minor rules. It then silently drifts away from the version that it renders configurations for.
The pin
exists to prevent exactly that drift.

No preset groups the mise tools. So the `groupName: "talos"` of this rule puts the CLI pin in the
Talos PR, beside the installer image.

### pocket-id — the operator halts on an unsupported version

pocket-id-operator reconciles pocket-id. The operator refuses to manage a pocket-id that is newer
than the release it was built against. `reconcileVersion` calls `haltIfUnsupportedVersion`. That
function logs _"Pocket-id version is unsupported by this operator; halting"_ and stops the
manager. The container then stays in CrashLoopBackOff forever.

pocket-id itself continues to serve, because nothing changes the Deployment. The only symptom is
that every `PocketIDOIDCClient`, `PocketIDUser` and `PocketIDUserGroup` silently stops
reconciling.

That happened once. A pocket-id minor automerged on the day of its release, on the "Auto-merge all
minor updates" rule. The newest operator release named that version as its
`firstUnsupportedVersion`.

The bump is one-way. Pinning back does NOT undo it. pocket-id runs its schema migrations on the
first start. An older binary refuses to start against a newer schema (_"downgrades are not
allowed"_). The team tried to pin back, and the IdP went down until the team restored the bump. To
recover from a bad bump, you need a database restore, not a redeploy. That is the whole reason
these bumps must not automerge.

The operator lags pocket-id by days to weeks on every minor, so this will happen again. Bump only
after an operator release lists the target version as tested.

### Python — hold below 3.15

The mise `python` pin is the interpreter that the `pypi:ansible-core` and `pipx:ansible-lint`
installs build against. 3.15.0 automerged on 2026-10-09 as a plain minor, and both tools stopped
installing. pyyaml 6.0.3 ships no `cp315` wheel, and uv refuses to build it from source. When
`https://pypi.org/pypi/PyYAML/json` lists a `cp315` wheel, drop the `allowedVersions` guard.

This repo no longer pins `python`. The pin comes from `base.toml` in
<https://git.dcunha.io/exikle/mise-config>. The guard lives beside it, in `.renovaterc.json` of
that repo. This section is the rationale, and that file is the rule.

The guard matches on `matchDepNames`, not `matchPackageNames`. The mise manager looks up `python`
as the package `python/cpython`, and `matchPackageNames` matches that package name. So a
`matchPackageNames: ["python"]` guard matched nothing, and #2695 reopened the 3.15.0 bump anyway.

### The zer0ver guard

The zer0ver policy (preset 5.0.0+) reclassifies 0.x minors as breaking. They get a
`feat(scope)!:` prefix and land on a `major-` branch. That changes only the presentation.
`updateType` stays `"minor"`, so an unguarded minor-automerge rule still merges them. The upstream
preset ships no guard. So the guard is on the shared minor-automerge rule in `default.json`, as
`matchCurrentVersion: "!/^v?0\\./"`.

Without the guard, 0.x minors on core infrastructure automerge to production unattended.

The labels do not follow that split. The `type/*` labels come from the `packageRules` of
`default.json`, and each one matches on `updateType`. So a 0.x minor gets `type/minor`, although
its title carries the breaking `!`. The `prHeader` here also says `🔵 minor`, because it picks its
colour by `updateType`, and zer0ver does not change `updateType`.

### kube-prometheus-stack — a CRD source, not a deployment

Bumps to `kube-prometheus-stack` in `kube/clusters/artemis/bootstrap/helmfile.d/00-crds.yaml` have
no effect until a cluster rebuild. Nothing installs the release. Bootstrap keeps only its CRDs.
The live `monitoring.coreos.com` CRDs are still orphans from a HelmRelease that was removed
~2026-05-16.

Three bumps have landed, and some showed as `feat(container)!:` majors. Nothing reconciles from
them, so do not triage one as a risky major. The risk comes at the next bootstrap, not on merge.
For the background, read `observability.md` § Where the `monitoring.coreos.com` CRDs come from.

### Disabled managers

The shared default holds the disables for the artifact actions. Forgejo supports them only up to
v3.

---

## Grafana Dashboards

Dashboard revisions are bare integers, so every bump reads as `major`. That is the shape of the
datasource, not a breaking change. For this reason, `cluster.json` sets `automerge: true` and
`ignoreTests: true` on `matchDatasources: ["custom.grafana-dashboards"]` +
`matchUpdateTypes: ["major"]`. `.renovaterc.json5` turns this off for Frostlink.

This repo has no `automergeType` override. For why `branch` is not an option, read
Commit Signing — Model A above.

---

## Lock File Maintenance

The `lockFileMaintenance` block lives in `cluster.json`, not in this repo.

This repo has no `mise.lock` any more (`lockfile = false` in `.mise/config.toml`). Every mise tool
is an exact pin that Renovate bumps, so a lock only added churn. Lock maintenance here
now refreshes the OpenTofu `.terraform.lock.hcl` files under `terraform/stacks/`.

Lock maintenance needs its own schedule (monthly, set in the preset). Without it, the top-level
nightly window runs it every night.

Automerge is off on purpose. Provider lock bumps change what talks to real hardware, so a human
reads the monthly PR.

---

## Grouping

Every shared group lives in `cluster.json` of `exikle/renovate-config`. To list them, run
`git -C ~/renovate-config show origin/main:cluster.json | grep -n groupName`. The only local group
is the Frostlink `cnpg` group in `.renovaterc.json5` (§ Frostlink). For `minimumGroupSize`, read
the last paragraph of § Schedule and release age.

---

## Schedule and release age

```json5
schedule: ["* 0-3 * * *"],
updateNotScheduled: true,
```

This repo sets these two values. The shared default supplies the timezone and
`minimumReleaseAgeBehaviour: "timestamp-optional"`.

Renovate creates branches only from 00:00 to 03:59 in the repo timezone (America/Toronto).
`updateNotScheduled: true` lets every hourly run of the `infrastructure` RenovateJob update and
merge the open branches, at any hour. So a green PR from the night can roll out to the cluster
during the day.

With `updateNotScheduled: false`, Renovate skips an open branch outside the window. It also skips
the automerge of that branch. Then only the four passes in the night merge anything, and the
queue grew (2026-11-21). A ticked rebase box in the PR body overrides the window in both cases.

### Three RenovateJobs

The operator runs one cron schedule per RenovateJob, in UTC. So each group of repos that needs its
own pace gets its own job. The three jobs live in
`kube/clusters/artemis/apps/kube-system/renovate-operator/jobs/`. They share the `default`
RenovateJobTemplate, which holds the image, the provider, the secret and the webhook.

| Job              | Repos                                                                   | Schedule (UTC)                      |
| ---------------- | ----------------------------------------------------------------------- | ----------------------------------- |
| `infrastructure` | home-infra, dotfiles                                                    | every hour, at minute 20            |
| `containers`     | containers                                                              | every 6 hours, at minute 30         |
| `apps`           | every other repo, except the ones that `renovatejob-apps.yaml` excludes | Mondays, hourly from 04:15 to 10:15 |

The `apps` job runs only on Monday, because the `app` preset of `exikle/renovate-config` sets
`schedule: ["before 6am on monday"]` (America/Toronto). Outside that window, Renovate does nothing
to an app. It also merges only inside the window.

With one run per day, an app gets one Monday run, and that run comes before its CI finishes. The
update then merges one week later. Hourly runs inside the window let a PR open and merge on
the same morning. The range from 04:15 to 10:15 covers the window in both EST and EDT.

A Forgejo webhook names its job in the URL (`?namespace=kube-system&job=<name>`). home-infra points
at `infrastructure`, and containers points at `containers`. If you rename a job, change these URLs
too. A new RenovateJob runs once when it is created, outside its schedule.

### The cache on atlas

Each run is a new pod, so without a cache Renovate forgets everything between runs. On Forgejo it
then downloads the list of every PR that the bot ever opened (3073 in home-infra on 2026-11-21).
That took about 7 minutes of each 11-minute run. No Renovate setting limits that download. The
PR list lives in the repository cache, and Renovate stores that cache only on local disk or in S3.

The `default` RenovateJobTemplate mounts the NFS share `10.10.99.100:/mnt/atlas/renovate-cache`
at `/cache`. It sets `RENOVATE_CACHE_DIR=/cache` and `RENOVATE_REPOSITORY_CACHE=enabled`. Every
job and every repo shares the folder. The `truenas` OpenTofu stack owns the dataset and the share.
The folder owner is `kubernetes:kubernetes`, set by hand, the same as the Kopiur folder. The
provider has no field for the owner.

On 2026-11-21 a run with an empty cache took 783 s. The next run took 123 s, and its start-up
step fell from 373 s to 6 s. The log line `Repository cache is restored from revision N` shows that
a run read the cache.

The package cache is separate. It holds the results of version lookups. It lives in the shared
Dragonfly, index 3 (`RENOVATE_REDIS_URL`), as in most home-ops setups. When `redisUrl` is set,
Renovate puts the package cache in Redis and keeps only the repository cache in `/cache`
(`lib/util/cache/package/backend.ts`). The `kube-system` namespace is in `dragonfly-clients` for
this reason.

Two more settings make the package cache work for ghcr.io:

- `RENOVATE_CACHE_PRIVATE_PACKAGES=true`. Renovate caches docker tag lists only for Docker Hub
  unless this is set (`lib/util/cache/package/with-cache.ts`).
- `RENOVATE_CACHE_TTL_OVERRIDE` keeps `datasource-docker-tags` and `datasource-docker-releases-v2`
  for 360 minutes. The default is 30 minutes, so an hourly run never found a cached tag list.

Without them, every run walked the full tag list of `ghcr.io/immich-app/immich-machine-learning`,
and ghcr.io answered with HTTP 429 partway through (2026-11-21). The cost is that Renovate can see
a new docker version up to 6 hours late.

The `infrastructure` job runs at minute 20, not minute 0. Other home-ops repos report that ghcr.io
throttles most at the top of the hour.

The caches are disposable. If you delete the folder contents or flush index 3, the next run is
slow once and then writes the cache again.

`timestamp-optional` lets an update through `minimumReleaseAge` when its datasource publishes no
release timestamp. The default (`timestamp-required`) holds such an update pending forever. That
is why the Talos and Kubernetes PRs of Frostlink never opened (frostlink#345).

Do not extend `home-operations/renovate-config`. That repo was deleted around 2026-10-30. The
`type/*` labels that it gave now live in `default.json` of `exikle/renovate-config`. The
label-based PR-review merge job that read those labels was retired on 2026-11-16 (forgejo-workflows
commit `f27e27f`). kritika reviews PRs now (§ AI review on pull requests). `default.json` still
names the old job in two descriptions.

`minimumGroupSize: 2` does not raise a lone update as its own PR. Renovate holds it on the
Dependency Dashboard under _Group Size Not Met_ until someone ticks its checkbox. `envoy-gateway`
matches only one package, so it has no `minimumGroupSize`. For the groups that keep it: if a
single-package bump seems overdue, look in that dashboard section.

---

## The PR body

The default body of Renovate has eight slots:
`{{{header}}}{{{table}}}{{{warnings}}}{{{notes}}}{{{changelogs}}}{{{configDescription}}}{{{controls}}}{{{footer}}}`.
This repo drops two of them.

| Slot                | Why it is gone                                                       |
| ------------------- | -------------------------------------------------------------------- |
| `configDescription` | ~10 identical lines per PR: schedule, rebasing policy, how to ignore |
| `footer`            | the Mend attribution line and its separator                          |

That boilerplate was most of the body. Two things replace it:

- A one-line verdict (`prHeader`).
- A callout that appears only when something blocks the merge (`prBodyNotes`).

### Silence means safe

`prBodyNotes` renders per upgrade. Renovate drops empty results and removes duplicates
(`lib/workers/repository/update/pr/body/notes.ts`). So a conditional note costs nothing on the PRs
that it does not apply to. A body with no ⛔/⚠️ callout is a PR with nothing to do.

Each callout carries the rationale of its rule, not a generic warning. So the reason that a bump
is held shows on the PR, and not only in this file. Every `automerge: false` guard above has a
callout, the `cilium` group included. So does every major update, through the `⛔ Major` rule in
`cluster.json`.

### Why the body cannot say "this automerges"

`automerge` is not a template field. `lib/util/template/index.ts` exports `allowedFields` and
`exposedConfigOptions`. Renovate proxies anything outside those two lists to `undefined` and logs
it as an unknown variable. `updateType`, `isMajor`, `isGroup`, `groupName`, `depName` and `labels`
are available. `automerge` is not, and it never was.

That is the whole reason for the inverted design. The `🚦 Automerge: Enabled/Disabled` line of
Renovate lives inside `configDescription`, which the team dropped. The only honest signal left is
the absence of a callout.

`prBodyNotes` is `mergeable: true`. So every matching `packageRules` entry adds its note, and one
does not override the other. A major update to a held package gets both the `⛔ Major` note and the
note of the hold.

### The verdict line

Renovate compiles `prHeader` against the branch configuration. So it picks its colour by
`updateType`. When `isGroup` is set, it falls back to `groupName`:

```text
🟢 **patch** · ghcr.io/renovatebot/renovate
🔴 **major** · ghcr.io/home-operations/sonarr
🔵 **minor** · cilium group
⚪ **digest** · docker.io/library/python
```

### Keep it thin — kritika sits below it

kritika posts the review on the same PR, and it renders the change with flate. The body has one
job: _what moved and do I have to act_. Anything in the body that looks like risk analysis is a
second copy that drifts.

### Validating a change to it

Neither `flate` nor the schema finds a broken handlebars template. The slot only renders empty.

```bash
npx --yes --package renovate@<version> renovate-config-validator .renovaterc.json5
```

That command checks the configuration shape. To check the template output itself, compile
`prHeader` with handlebars and the `equals` helper against a fake upgrade object. The helper list
is in `lib/util/template/index.ts`.

---

## AI review on pull requests

kritika reviews every pull request on this repo (#3334). It runs on Artemis in the `kritika`
namespace. It acts on Forgejo as `dusk-bot`, through a Generic JWT authorized integration of that
user. Its repo rules are in `.kritika.yaml`. Its instance configuration is in the HelmRelease under
`kube/clusters/artemis/apps/kritika/`.

kritika posts a summary comment, inline findings, and a commit status named `Kritika / Review`.

The instance configuration sets `trigger.settle: 60s`. kritika then waits 60 seconds after a push
before it starts the review. Without the wait, it started about one second after a push. It reads
the merge base of the PR from Forgejo, and Forgejo computes that merge base in the background after
a push. A rebased PR was then diffed against its old base. On 2026-11-22, #3380 changed one line,
but its review got 30 files from two days of `main`. A diff that large also overflows the answer
limit of the confidence step, which is fixed at 4096 tokens in kritika. The status is then `error`
with "confidence not scored". If a PR still shows that error, comment `@dusk-bot review` on it.

### Merge on a green check

kritika does not approve. `dusk-bot` opens the Renovate PRs, and Forgejo does not let a user
approve its own PR. The gate is the `Kritika / Review` status:

1. A second model scores each PR that a bot opens, from 0 to 5 (`confidence.gate` with `pr.bot` in
   the HelmRelease). `dusk-bot` counts as a bot, because the Forgejo connection lists it under
   `bots`.
2. If the score is below 4, the status fails. If kritika cannot score the PR, the status is an
   error.
3. Patch, minor and digest rules set `ignoreTests: false`. So Renovate merges those PRs only when
   every status on them is green.

`.renovaterc.json5` and the shared presets still decide what can merge on its own. Two rules skip
the gate with `ignoreTests: true`:

- Grafana dashboards on Artemis (`cluster.json`) automerge, even though every revision is a
  major. That is accepted, because a dashboard is read-only. `.renovaterc.json5` turns this off for
  Frostlink.
- Forgejo Actions (`default.json`) automerge the same way.

No other major automerges. A package that a rule holds by name never automerges either.

`platformAutomerge` is `false`. Renovate merges each PR itself, one at a time, during its run. It
does not hand the merge to Forgejo, because Forgejo's `merge_when_checks_succeed` loses commits
when several PRs pass at once. Read § Never batch `merge_when_checks_succeed`.

`rebaseWhen` is `"conflicted"`. Without it, Renovate uses `behind-base-branch` when automerge is
on. Then each merge puts every other open PR behind `main`. Renovate rebases them, and the rebase
resets their checks to pending. So each hourly run merged only one PR, about three a night, and
the queue grew. With `"conflicted"`, Renovate rebases a PR only when it has a merge conflict. One
run merges every PR that has green checks. A PR can merge with checks that ran against an older
`main`. `main` allows this, because its branch protection has `block_on_outdated_branch: false`.

The review knows only what the PR body tells it. The release notes from Renovate are the
evidence.

---

## Merging a batch

Renovate PRs auto-merge through squash. To merge one PR or a batch by hand, use `fjo`, one PR at
a time (the command is below). Do not use `merge_when_checks_succeed` (§ Never batch
`merge_when_checks_succeed`).

The squash lands as `title (#N)` on main, signed by git.dcunha.io Instance.

### Never batch `merge_when_checks_succeed`

Queue this on one PR at a time. Every PR queued with `merge_when_checks_succeed` fires on the same
status event, and they race on the update of the `main` ref. The losers of that race come back
`merged=true` with a valid `merge_commit_sha`. But the commit stays dangling and never becomes
reachable from `main`. The bump silently does not land, and the API reports no error. A batch of
nine once lost three PRs this way. The team had to recover them by cherry-pick.

This flag has two more traps:

- It never fires if the checks already passed. No new status event arrives to trigger it, so the
  PR only sits there and looks queued.
- `merged=true` is not proof that the change reached `main`.

Merge one PR after the other with `fjo`, and make sure that each one landed.
`FORGEJO_HOST` and `FORGEJO_TOKEN` come from the mise env of the repo, so there is no `--login` to
pass:

```bash
fjo pr merge <PR_NUMBER> --squash --delete-branch -R Exikle/home-infra
git fetch origin main && git branch -r --contains <merge_commit_sha> | grep -q origin/main \
  && echo LANDED || echo LOST
```

To recover a lost commit:

1. Run `git fetch origin <dangling-sha>`.
2. Cherry-pick it onto a branch off the current `main`.
3. Open a normal PR.

---

## Internal Host Access

Renovate v44.79.0 added `internalHostAccess`. The default is `warn`. Every request to a host that
resolves into RFC1918 / loopback / CGNAT / link-local space logs this line:

```text
HTTP request to an internal host, which `internalHostAccess=block` would refuse
```

The default becomes `block` in v45. From then on, a host without a grant stops the lookup. Two
hosts trigger it here:

- `git.dcunha.io` (hostType `forgejo`, every discovered repo).
- `registry.dcunha.io` (hostType `docker`, Artemis only).

The grant lives in `RENOVATE_HOST_RULES`, in the template of the `renovate-secret` ExternalSecret
(`kube/clusters/artemis/apps/kube-system/renovate-operator/jobs/externalsecret.yaml`). It is not in
`.renovaterc.json5`. The same value also gives Renovate a login for `ghcr.io`, with the GitHub
token. Without that login, a single 429 from ghcr.io stops the whole run before the merge step.
The grant part is:

```text
RENOVATE_HOST_RULES=[{"matchHost":"https://git.dcunha.io/","allowInternal":true},
                     {"matchHost":"https://registry.dcunha.io/","allowInternal":true}]
```

### Why it cannot go in the repo config

A repo can set `hostRules` as a whole, but `allowInternal` itself is admin-only. Renovate strips it
from repository and preset configuration. A top-level occurrence raises a fatal `Security`
validation error that stops the run. `internalHostAccess` is a self-hosted global option, and a
repo cannot set it at all. Every RenovateJob reads the same secret through the `default` template.
So the env var corrects every repo at once.

### Two traps

- Any `matchHost` rule is an implicit grant. Under `warn`/`block`, a rule that only sets a timeout
  still permits internal access to that host. If you add a credential rule for an internal host,
  it silently grants access. To keep the rule without the grant, set `allowInternal: false`.
- The exemption for the platform endpoint matches the origin exactly. `isPlatformEndpoint()`
  compares scheme + host + port against `endpoint`. So a different port, or a sibling host on the
  same domain, is not covered. That is why `registry.dcunha.io` warns, even though `git.dcunha.io`
  is the configured Forgejo endpoint.

The team has not set `internalHostAccess=block` yet, on purpose. To enforce it early gives nothing
over waiting for v45. Also, if the team missed an internal host, enforcement stops every run.

---

## Where Artemis and Frostlink deliberately differ

The two clusters share one `.renovaterc.json5`, and the mechanisms are similar. So the
differences are easy to copy wrongly. The rules of Frostlink are scoped to
`kube/clusters/frostlink/**` (§ Frostlink below). These differences are intentional:

|                            | Artemis                                      | Frostlink                                                      |
| -------------------------- | -------------------------------------------- | -------------------------------------------------------------- |
| Container-digest automerge | unscoped: every `docker` digest              | scoped to `matchPackageNames: ["/home-operations/"]`           |
| Talos automerge guard      | shared (`cluster.json`), datasource-agnostic | same shared guard, plus a local 7-day `minimumReleaseAge` hold |
| tuppr guard                | not needed (the Talos guard covers it)       | `matchFileNames` + `minimumReleaseAge: "7 days"`               |
| Grafana dashboards         | automerge (`cluster.json`)                   | do not automerge                                               |
| Update window              | `* 0-3 * * *`                                | at any time                                                    |
| CNPG updates               | not grouped locally                          | one `cnpg` group, in a Saturday window (`* 4-6 * * 6`)         |

Before you "harmonise" a row, read the rationale of both files for it.

---

## Frostlink

Frostlink has no `.renovaterc.json5` of its own. Its rules sit in the root file and carry
`matchFileNames: ["kube/clusters/frostlink/**"]`. Read the file for the rules. This section holds
only the reasons. The two cluster presets and the guards above apply to both clusters.

- Single node. A merged tuppr bump reboots the only node, and there is nowhere to drain to. So the
  tuppr upgrade files (`kube/clusters/frostlink/apps/system-upgrade/tuppr/upgrades/`) never
  automerge, and they wait 7 days. The never-automerge rule must stay after the broad automerge
  rules, because later `packageRules` win. The Talos and Kubernetes groups come from the cluster
  preset.
- Why Talos and Kubernetes PRs open at once. The talos-factory datasource publishes no release
  timestamp. Neither do the `ghcr.io/siderolabs/kubelet` and `registry.k8s.io/kube-proxy` tags. So
  Renovate cannot enforce the 7-day wait. `automerge: false` is what keeps them safe. The talosctl
  pin in `.mise/config.toml` has a timestamp, so its 7 days apply.
- Kubernetes is pinned in two files. One is `kubernetesupgrade.yaml` (kubelet). The other is
  `kube/clusters/frostlink/talos/patches/controlplane.yaml` (`kube-proxy`). The second pin is
  necessary because Talos 1.14 wants an explicit `image:` on a disabled `KubeProxyConfig` (read
  `oci-talos.md`). The Kubernetes group moves both in one PR. CoreDNS is not in the group. Its tag
  is Talos's own pin, and it is not tied to the Kubernetes version.
- Talos version in two places: `talosupgrade.yaml` and the talosctl pin. The package-level Talos
  rule keeps the CLI from drifting. The reason is that an old client rejects a newer configuration
  document (`oci-talos.md`, the client-version note at the top).
- 0.x guard matters here. Most of the control plane is 0.x (flux-operator, kopiur, ksgate,
  dragonfly-operator, both victoria-metrics charts). Without the zer0ver guard, a 0.x minor merges
  unattended.
- Container digests. Only trusted digests (`/home-operations/`) automerge. Other digests wait for a
  human.
- Update window. Frostlink updates at any time, not only in the Artemis window.
- Groups. Cilium and Envoy Gateway use the shared groups of `cluster.json`. The `cilium` group has
  `minimumGroupSize: 2`, so a lone Cilium chart bump waits on the Dependency Dashboard
  (§ Schedule and release age). The local CNPG group batches the updates that roll the Postgres
  instances and move the primary, in a Saturday window. It does not prevent the outage
  (`database.md` § Why clients must tolerate a primary change).
- Dashboards. Grafana dashboard updates do not automerge on Frostlink.
- external-dns never automerges, on both clusters (`cluster.json`). v0.22.0 changed the default
  annotation prefix with no fallback, and it deleted a whole zone on Frostlink.
- `# renovate:` marker in `talosupgrade.yaml`. It resolves through the talos-factory datasource
  (`talosFactory` preset). If you drop the preset, the marker stops resolving.

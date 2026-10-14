# Renovate — Preset Pinning, Automerge Policy, Custom Managers

The config is split three ways, and each section below says which layer a rule lives in:

- **Shared default** — `default.json` in <https://git.dcunha.io/exikle/renovate-config>, extended by
  every repo on the instance.
- **Cluster preset** — `cluster.json` in the same repo, extended by frostlink and Artemis only.
- **This repo** — `.renovaterc.json5` at the root. It extends the first two, so its `packageRules`
  come last and win. It is deliberately bare of prose; every "why" below used to be a comment block
  in it.

The shared repo's own files are the source of truth for what they carry; this doc records only the
rationale and does not restate their rules. **A change to the shared preset reaches every repo on
its next Renovate run**, so check what it does to frostlink's guards before merging it there.

Upstream presets: <https://github.com/home-operations/renovate-presets>

Every PR against `main` also gets an AI review comment from the shared `pr-review.yaml` in
`Exikle/forgejo-workflows`, which `.forgejo/workflows/pr-review.yaml` calls. It is a sticky comment,
not a status check. Its merge job squash-merges an approved minor or patch dusk-bot PR that carries
no hold; the rules, and why a never-automerge rule here must carry a `⛔` note, are in Artemis's
`.agents/references/renovate.md` § Merge on approve, which wins.

The `renovate-presets` pin lives in the shared default, so every repo moves together. Bump it there,
and only after checking the target tag is self-contained (below). The two cluster repos made
opposite signing choices; the divergence table is in Artemis's
`.agents/references/renovate.md` § Where Artemis and Frostlink deliberately differ.

---

## Preset Pinning

This repo's `extends` is the shared default, the cluster preset, and the one `apps/` preset only it
needs (`phanpy`). The root `renovate-presets` pin, the semantic-commit and timezone presets, and the
`labels.json5` / `groups.json5` files from `home-operations/renovate-config` are all in the shared
default. Every `renovate-presets` entry carries the same tag, `phanpy` here included — keep it equal
to the one in the shared default.

`home-operations/renovate-config` publishes no tags, so the shared default pins it by commit. Its own
default preset is not extended: it brings an automerge type, commit arrows and a schedule that
conflict with `renovate-presets`.

### Why every entry carries an explicit tag

`default.json` used to reach its content through nested `github>home-operations/renovate-presets//config/...`
references that carried **no tag**. Renovate resolves an untagged nested preset against the preset
repo's **default branch**, not the tag its parent was pinned at, so the pin was never real. When
upstream deleted those directories from `main`, this repo started 404ing on the nested fetch and
**Renovate aborted in the init phase** — no dependency updates landed at all until the pin moved.

**Since 7.0.0 the files are self-contained.** Before bumping this pin to any
new tag, verify the target tag has no self-references:

```bash
curl -sf "https://api.github.com/repos/home-operations/renovate-presets/git/trees/<TAG>?recursive=1" \
  | jq -r '.tree[]|select(.type=="blob")|.path'
# then, for default.json and each apps/*.json5 the shared repo or this repo extends:
curl -sf "https://raw.githubusercontent.com/home-operations/renovate-presets/<TAG>/default.json" \
  | grep -n "home-operations/renovate-presets" || echo "self-contained"
```

A silent abort looks exactly like "no updates were due" — check the Renovate log, not the PR list.

### Why the apps/ presets are listed individually

**The `apps/` presets are opt-in** — the root preset no longer pulls them in, so every
app-specific manager/datasource this repo depends on has to be listed explicitly. Dropping one
is silent: the custom manager simply stops extracting and the dependency goes stale with no error.

`cnpg.json5` feeds `Cluster.spec.imageName` in `database/postgres` and `talosFactory.json5` the
`custom.talos-factory` customDatasource; both come in through the cluster preset. `phanpy.json5`
feeds phanpy's `<calver>.<sha>` tags and is the one listed in this repo.

Deliberately absent: `grafanaDashboards` (no dashboards here — VictoriaMetrics only),
`searxng`, `llamacpp`.

**`talosFactory` is extended for the datasource, not its manager.** Its own customManager only
scans `talos/**`, and nothing there carries a version — but tuppr's `TalosUpgrade` does, and the
default preset's generic `# renovate:` annotation manager (which scans every file) resolves that
marker against this datasource. Drop the preset and the marker in `talosupgrade.yaml` silently
stops resolving.

### The helm-values manager is narrowed to `helmrelease.yaml`

Since 8.0.0 the `helm-values` manager only scans `values.yaml`, `helmrelease.yaml` and `hr.yaml`
(plus `.yml` / `.j2` variants). **This is a no-op here only because every HelmRelease in this repo
is named `helmrelease.yaml`.** The `kubernetes` manager still uses the old broad glob, so it covers
what helm-values gave up; but a HelmRelease added under a different filename stops having its
`spec.values.image.*` block extracted, with no error.

---

## Commit Signing

`platformCommit: "enabled"` is set in this repo. The shared default supplies `automergeType: "pr"`
and `automergeStrategy: "squash"`; this repo overrides `automergeType` to `"branch"` for Forgejo
Actions only (the `Forgejo Actions merge as branches` rule).

Renovate commits through the Forgejo API rather than local git, so the instance SSH key signs
both the branch commits (`automergeType: "branch"`) and the squash merges (`automergeType: "pr"`).

Artemis dropped `platformCommit` and went squash-only. Here it is what keeps the two
`automergeType` paths on the same signer — **do not remove `platformCommit` or the branch override
without the other.**

---

## Automerge Policy

Rules are ordered; later `packageRules` win. The broad automerge rules (Forgejo Actions, trusted
Forgejo Actions, all patch updates, all minor updates except 0.x) are in the shared default. Trusted
container digests are local to this repo. The Talos and Kubernetes never-automerge guards are in the
cluster preset; the rest of the guards are in `.renovaterc.json5`. Extends load before local rules,
and the cluster preset loads after the default, so each guard overrides the broad automerge rules
beneath it.

The shared default also holds Go, npm, PyPI and crates updates for 3 days, and holds the
github-actions and Mise Tools groups for 3 days. Those holds are the same windows as the Forgejo
Actions rule. frostlink did not hold registry updates before the shared preset.

### The zer0ver guard

The zer0ver policy (preset 5.0.0+) reclassifies 0.x minors as breaking: they get a
`feat(scope)!:` prefix and land on a `major-` branch. **That is presentation only** — `updateType`
stays `"minor"`, so an unguarded rule still automerges them. The preset says as much: a guard
shipped upstream would just be overridden by the automerge rule, so the guard lives beside it in the
shared default as `matchCurrentVersion: "!/^v?0\\./"`. The shared labels also put `type/major` on
those 0.x minors.

Most of this cluster's control plane is 0.x — flux-operator, kopiur, ksgate, dragonfly-operator
and both victoria-metrics charts — so without the guard a 0.x minor on any of them merges to
production unattended.

### The tuppr guard

tuppr turns a merged version bump into a real cluster upgrade. Frostlink is a **single node**, so
both a Talos and a Kubernetes bump are full cluster downtime with nowhere to drain to.
"Auto-merge all patch updates" matches on update type with no package filter, so without this
guard a bump like `v1.14.0-rc.1 ➔ v1.14.0` would merge and reboot the cluster unattended.

```json5
{
    matchFileNames: ["kubernetes/apps/system-upgrade/tuppr/upgrades/**"],
    automerge: false,
    minimumReleaseAge: "7 days",
}
```

This one is local. **Must stay after the auto-merge rules** — later `packageRules` win; the broad
ones are in the shared default, which loads before it.

#### `timestamp-optional` is what makes these PRs open at all

The `custom.talos-factory` datasource and the `ghcr.io/siderolabs/kubelet` /
`registry.k8s.io/kube-proxy` docker tags return **no release timestamp**. Renovate's default
`minimumReleaseAgeBehaviour: "timestamp-required"` then treats every release as too young, forever:
the log says _"Marking N release(s) as pending … do not have a releaseTimestamp"_ and no PR ever
opens. That is why Talos and Kubernetes once sat on old versions until they were bumped by hand.

`minimumReleaseAgeBehaviour: "timestamp-optional"` is now set once in the shared default, so it
applies to every rule here rather than being repeated on each guard.

The cost: for those three packages the 7-day wait (local to this repo) cannot be enforced, so their
PRs open as soon as a release appears. `automerge: false` is what keeps them safe — nothing reboots the node until a
human merges. The talosctl pin in `.mise/config.toml` does carry a timestamp, so its 7 days still apply.

Tracking itself was never the problem: the default preset's generic `# renovate: datasource=…
depName=…` manager scans every file and already extracts the tuppr annotations and the kube-proxy
pin. No repo-local custom manager is needed (Artemis's own `custom.talos-factory` manager is
redundant with it).

#### The Talos rule is package-level, so it also covers the talosctl pin

The Talos version is pinned in **two** places, and only one is under the tuppr directory:

| Where                                | Datasource             |
| ------------------------------------ | ---------------------- |
| `tuppr/upgrades/talosupgrade.yaml`   | `custom.talos-factory` |
| `talos = "…"` in `.mise/config.toml` | mise manager           |

A file-scoped guard would leave the talosctl **CLI** automerging and drifting from the node —
which matters here, because talosctl decodes config documents client-side and an older client
rejects a v1.14 document before the node sees it (`.agents/references/talos.md`, the "Client version matters" note). So the **Talos** rule matches `matchPackageNames: ["siderolabs/talos"]` (deliberately not
datasource-scoped), sets `automerge: false`, and carries `groupName: talos` so the tuppr CR and the
talosctl pin land in one PR. That rule is in the cluster preset, so Artemis runs the identical
guard; only the 7-day hold on it is local to this repo.

#### Kubernetes has the same split — hence the Kubernetes Group

The Kubernetes version is pinned in **two** files, and the file-scoped guard only covers one:

| Where                                   | Package                      | Covered by the file guard? |
| --------------------------------------- | ---------------------------- | -------------------------- |
| `tuppr/upgrades/kubernetesupgrade.yaml` | `ghcr.io/siderolabs/kubelet` | yes                        |
| `talos/patches/controlplane.yaml`       | `registry.k8s.io/kube-proxy` | **no**                     |

The `kube-proxy` pin exists because Talos 1.14 requires an explicit `image:` on a **disabled**
`KubeProxyConfig` — see `.agents/references/talos.md`. Left ungrouped it would bump on its own and
drift away from the kubelet version.

The **Kubernetes Group** rule solves it package-side rather than by widening `matchFileNames`:
it groups `kubelet` and `kube-proxy` into one PR, so both files always move together. The group and
its `automerge: false` are in the cluster preset, which matches the union of both clusters'
packages — the apiserver, controller-manager and scheduler entries are there for Artemis and never
match here, since nothing in this repo pins them. The 7-day hold is a separate local rule; a grouped
PR touches `kubernetesupgrade.yaml` and merging it makes tuppr reboot the single node. **The
never-automerge rule must stay after the auto-merge rules**, like the guard above; later
`packageRules` win, and the extends order guarantees it.

`registry.k8s.io/coredns/coredns` is deliberately **not** in the group. Its version is Talos's own
pin (`v1.14.x`), not derived from the Kubernetes version, so grouping it would produce a PR mixing
two unrelated version lines. It is also a disabled component, so a drifted tag pulls nothing.

### Artifact actions are disabled

`actions/upload-artifact` and `actions/download-artifact` are pinned off entirely, in the shared
default: Forgejo only supports up to v3, and v4+ uses a GHES-incompatible backend.

### Tekton runner built-ins are disabled

`tekton/setup` and `tekton/pipeline` in the shared `oci-push.yaml` are steps provided by
the Tekton runner, not repositories. Without the rule Renovate looks them up as GitHub tags, fails,
and the Dependency Dashboard shows a "Package lookup failures" warning on every run. The rule is in
the shared default.

---

## Grouping

The shared default also brings the `github-actions` and Mise Tools groups and the Go, Rust and Node
toolchain groups (from `groups.json5`, pinned in the shared repo).

`minimumGroupSize: 2` on flux-operator (cluster preset) — the operator and instance charts move
together. A branch below its minimum group size is **not** raised individually: Renovate holds it under
"Group Size Not Met" until someone ticks it on the Dependency Dashboard.

**A one-dependency group never opens a PR.** That is why Cilium and Envoy Gateway are not grouped.
Each has exactly one dependency here (the chart's `OCIRepository`; the bootstrap helmfile reads
Cilium's tag from that file), so a group would hold their updates forever. Cilium has its own
local `automerge: false` rule instead: it is the CNI of a single node, and a bad release takes every
pod's networking down. Envoy Gateway follows the normal automerge rules.

### CNPG group — the one that exists for blast radius, not tidiness

The group rule and its Saturday schedule are local to this repo; the `cnpg.json5` manager is in the
cluster preset. Every update to `Cluster.spec.imageName` rolls the instances and moves the primary, which clients
feel as an outage. Grouping them with the operator behind `schedule: ["* 4-6 * * 6"]` makes it
predictable and less frequent. **It does not prevent it.** Why the clients care:
`database.md` § Why clients must tolerate a primary change.

---

## Custom Manager — app-template schema modeline

This manager is in the cluster preset. The app-template HelmReleases point their `# yaml-language-server:` modeline at the chart's **own**
HelmRelease schema, which is the only thing that validates `spec.values`; the generic
`helmrelease_v2.json` validates the envelope and stops there. That URL carries the chart version
in its git tag, so without this manager the schema silently pins to whatever version was current
when the file was written and drifts every time the chart moves.

It uses the same `depName` as the per-app `ocirepository.yaml`, so the schema bump rides along
with the chart bump rather than arriving as a second, separate PR. This matters because the chart
version lives in two places per app (the OCIRepository and the modeline) and only this keeps the
two halves in step.

---

## Lock File Maintenance

The schedule and the enable flag are in the cluster preset, which Artemis also extends. This repo
has no lock files for it to refresh: there is deliberately no `.mise/mise.lock`
(`lockfile = false` in `.mise/config.toml`), because every mise tool is an exact pin that the Mise
Tools Group bumps and a lock only added churn. The block is a no-op here.

---

## Merging a batch

Merge Renovate PRs with the `triage-renovate` skill: one PR at a time, verifying each landed on
`main`. Queueing several with `merge_when_checks_succeed` races on the `main` ref and silently
drops commits.

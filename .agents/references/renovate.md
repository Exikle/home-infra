# Renovate — Preset Pinning, Automerge Policy, Custom Managers

All of it lives in `.renovaterc.json5` at the repo root. That file is deliberately bare of
prose; every "why" below used to be a comment block in it.

Upstream presets: <https://github.com/home-operations/renovate-presets>

Every PR against `main` also gets an AI review comment from `.forgejo/workflows/pr-review.yaml`.
It is advisory only — a sticky comment, not a status check, so it never gates a merge.

The preset pin and the `extends` list are in `.renovaterc.json5` (both repos pin the same tag).
Bump only after checking the target tag is self-contained (below). The two repos extend different
`apps/` presets and made opposite signing choices; the divergence table is in Artemis's
`.agents/references/renovate.md` § Where Artemis and Frostlink deliberately differ.

---

## Preset Pinning

The `extends` list is in `.renovaterc.json5`: the root preset, three `apps/` presets, and the
semantic-commit and timezone presets, every entry pinned to the same tag.

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
# then, for default.json and each apps/*.json5 this repo extends:
curl -sf "https://raw.githubusercontent.com/home-operations/renovate-presets/<TAG>/default.json" \
  | grep -n "home-operations/renovate-presets" || echo "self-contained"
```

A silent abort looks exactly like "no updates were due" — check the Renovate log, not the PR list.

### Why the apps/ presets are listed individually

**The `apps/` presets are opt-in** — the root preset no longer pulls them in, so every
app-specific manager/datasource this repo depends on has to be listed explicitly. Dropping one
is silent: the custom manager simply stops extracting and the dependency goes stale with no error.

`cnpg.json5` feeds `Cluster.spec.imageName` in `database/postgres`, `phanpy.json5` phanpy's
`<calver>.<sha>` tags, and `talosFactory.json5` the `custom.talos-factory` customDatasource.

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

```json5
platformCommit: "enabled",
automergeStrategy: "squash",
```

Renovate commits through the Forgejo API rather than local git, so the instance SSH key signs
both the branch commits (`automergeType: "branch"`) and the squash merges (`automergeType: "pr"`).

Artemis dropped `platformCommit` and went squash-only. Here it is what keeps the two
`automergeType` paths on the same signer — **do not remove one without the other.**

---

## Automerge Policy

Rules are ordered; later `packageRules` win. The automerge rules (trusted container digests,
Forgejo Actions, all patch updates, all minor updates except 0.x) and the guards that override
them are in `.renovaterc.json5`; the guards at the bottom exist to override the broad automerge
rules above them.

### The zer0ver guard

The zer0ver policy (preset 5.0.0+) reclassifies 0.x minors as breaking: they get a
`feat(scope)!:` prefix and land on a `major-` branch. **That is presentation only** — `updateType`
stays `"minor"`, so an unguarded rule here still automerges them. The preset says as much: a
guard shipped upstream would just be overridden by this rule, so it has to live here as
`matchCurrentVersion: "!/^v?0\\./"`.

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
    minimumReleaseAgeBehaviour: "timestamp-optional",
}
```

**Must stay after the auto-merge rules** — later `packageRules` win.

#### `timestamp-optional` is what makes these PRs open at all

The `custom.talos-factory` datasource and the `ghcr.io/siderolabs/kubelet` /
`registry.k8s.io/kube-proxy` docker tags return **no release timestamp**. Renovate's default
`minimumReleaseAgeBehaviour: "timestamp-required"` then treats every release as too young, forever:
the log says _"Marking N release(s) as pending … do not have a releaseTimestamp"_ and no PR ever
opens. That is why Talos and Kubernetes once sat on old versions until they were bumped by hand.

The cost: for those three packages the 7-day wait cannot be enforced, so their PRs open as soon as
a release appears. `automerge: false` is what keeps them safe — nothing reboots the node until a
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
talosctl pin land in one PR. Same shape as Artemis's guard.

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
it groups `kubelet` and `kube-proxy` into one PR, so both files always move together (the
apiserver, controller-manager and scheduler entries were dropped — nothing in this repo pins
them). It carries its own `automerge: false`, `minimumReleaseAge: "7 days"` and
`minimumReleaseAgeBehaviour: "timestamp-optional"`, because a grouped PR touches
`kubernetesupgrade.yaml` and merging it makes tuppr reboot the single node. **It must stay after the auto-merge rules**, like the guard
above; later `packageRules` win.

`registry.k8s.io/coredns/coredns` is deliberately **not** in the group. Its version is Talos's own
pin (`v1.14.x`), not derived from the Kubernetes version, so grouping it would produce a PR mixing
two unrelated version lines. It is also a disabled component, so a drifted tag pulls nothing.

### Artifact actions are disabled

`actions/upload-artifact` and `actions/download-artifact` are pinned off entirely: Forgejo only
supports up to v3, and v4+ uses a GHES-incompatible backend.

### Tekton runner built-ins are disabled

`tekton/setup` and `tekton/pipeline` in `.forgejo/workflows/oci-push.yaml` are steps provided by
the Tekton runner, not repositories. Without the rule Renovate looks them up as GitHub tags, fails,
and the Dependency Dashboard shows a "Package lookup failures" warning on every run. Same rule as
Artemis.

---

## Grouping

`minimumGroupSize: 2` on flux-operator — the operator and instance charts move together. A
branch below its minimum group size is **not** raised individually: Renovate holds it under
"Group Size Not Met" until someone ticks it on the Dependency Dashboard.

**A one-dependency group never opens a PR.** That is why Cilium and Envoy Gateway are not grouped.
Each has exactly one dependency here (the chart's `OCIRepository`; the bootstrap helmfile reads
Cilium's tag from that file), so a group would hold their updates forever. Cilium has its own
`automerge: false` rule instead: it is the CNI of a single node, and a bad release takes every
pod's networking down. Envoy Gateway follows the normal automerge rules.

### CNPG group — the one that exists for blast radius, not tidiness

Every update to `Cluster.spec.imageName` rolls the instances and moves the primary, which clients
feel as an outage. Grouping them with the operator behind `schedule: ["* 4-6 * * 6"]` makes it
predictable and less frequent. **It does not prevent it.** Why the clients care:
`database.md` § Why clients must tolerate a primary change.

---

## Custom Manager — app-template schema modeline

The app-template HelmReleases point their `# yaml-language-server:` modeline at the chart's **own**
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

Every tool in `.mise/config.toml` is pinned to an exact version, so `.mise/mise.lock` is what
records what those versions resolved to, and nothing else refreshes it.

It needs its **own schedule** — the top-level `"at any time"` would run this every pass.

Renovate runs `mise lock --bump` for this, which needs the mise binary. It is deliberately **not**
added to `allowedUnsafeExecutions` — mise >= 2026.7.12 gets safe mode (`MISE_SAFE=1`) instead,
which resolves versions over HTTP without letting project config shell out. If the runner ever
ships an older mise, Renovate logs a warning and skips; it does not half-write the lock.

Left off automerge on purpose: these tools back the `just` recipes and the `flux-oci-push` CI
workflow, so the monthly bump gets eyes on it.

---

## Merging a batch

Merge Renovate PRs with the `triage-renovate` skill: one PR at a time, verifying each landed on
`main`. Queueing several with `merge_when_checks_succeed` races on the `main` ref and silently
drops commits (`commit-style.md` § Renovate PR auto-merge).

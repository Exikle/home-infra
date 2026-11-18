---
name: reviewing-pull-requests
description: Use when you review a pull request or a Renovate update in home-infra, or check what a change under kube/ or terraform/ affects. Covers the upstream of a dependency, breaking changes, the Renovate rules of this repo, the search for what depends on a change, the flate render, tofu validate, and what a check proves.
---

# Reviewing pull requests in home-infra

Flux reconciles `kube/` from `main`. A merge rolls out within minutes, and there is no staging
cluster. Secrets are ExternalSecrets from 1Password. Judge key names and mappings from the
manifests.

`AGENTS.md`, which you get as context, describes the two clusters and the folder layout. Three
facts matter most for a review:

- Frostlink is one node. A restart of a core pod there (Cilium, CoreDNS, the Envoy gateway, CNPG)
  is an outage of every public site.
- A change under `kube/base/` reaches both clusters in one merge. Say so in the summary, and judge
  it against each cluster.
- A change under `kube/components/` or `kube/clusters/<cluster>/components/` reaches every app
  that lists the component.

Use the sections that fit the pull request: a Renovate update (a `renovate/` branch), a change
under `kube/`, a change under `terraform/`, and what a check proves, for every review.

## A Renovate update

Judge whether the update is safe to merge. Find what changed upstream between the old and the new
version, and whether anything in this repo depends on it.

### The update

Take from the title, body, labels and diff:

1. The package and its datasource: a container image, a Helm chart in an `OCIRepository`, a
   Forgejo Action, a mise tool, a Grafana dashboard, a Terraform provider, or a Renovate preset.
2. The old and the new version or digest.
3. The update type, from the `type/*` label.
4. The changed files. These are the places that use the dependency.

The body of the Renovate PR has a collapsed Release Notes section. Read it first. Go upstream when
it is missing, cut off or unclear. Always go upstream for a major update or a jump over several
versions, and read every release in between. Breaking changes land in the middle.

### Finding the upstream

- An image at `<registry>/<owner>/<repo>` usually comes from `<owner>/<repo>` on GitHub. If not,
  the PR body names the source.
- A chart comes from the `OCIRepository` of the app (`ocirepository.yaml`). Its `url` is the
  registry path, and `ref.tag` is the version. A path under
  `ghcr.io/home-operations/charts-mirror/<chart>` is a mirror. `apps/<chart>/metadata.yaml` in
  `home-operations/charts-mirror` names the upstream Helm repository.
- The chart version and the app version are different. Read the changelog of the chart, and of
  the application too when `appVersion` moved.
- A repository that publishes many charts puts the chart name in its release tags
  (`<chart>-1.2.3`). If you cannot find a release, list the releases and look for the chart name.
- A digest-only update moves no version. Say whether the tag was rebuilt, and from what.
- `gh` cannot reach Forgejo, and this repo is on Forgejo. Read GitHub with `curl`, for example
  `curl -s https://api.github.com/repos/<owner>/<repo>/releases?per_page=20`. Read a raw file with
  `curl -s https://raw.githubusercontent.com/<owner>/<repo>/<tag>/<path>`.

### What breaks

Flag these in each release:

- `BREAKING CHANGE`, `⚠` or `!:` markers.
- Removed or renamed Helm values, CRD fields, environment variables and flags.
- A required Kubernetes, Flux, Talos or kernel version.
- One-way schema or data migrations.
- Changed defaults: authentication, storage class, ports, probes.
- Deprecations that became errors, and new required keys with no default.
- Label values that changed while the key stayed, and resource names that dropped or gained a
  prefix. These break anything that selects on the old value, while a search for the key still
  matches.

Minor and patch updates carry breaking changes too.

An update can also move images that are not in the diff. A chart or an operator can change its
default images. Name each such image with its old and new version, read from the source of the
chart or operator at both versions. Nothing in this repo pins them, so the review is the only
place they show.

A breaking change that touches nothing here is not a finding. One sentence, with the search that
came up empty, is enough.

### The Renovate rules of this repo

`.renovaterc.json5` and the presets it extends (`exikle/renovate-config`, `default.json` and
`cluster.json`) decide how Renovate treats the update. The presets are not in the checkout. Read
them with `curl -s https://git.dcunha.io/exikle/renovate-config/raw/branch/main/<file>`.

Do not assume whether an update merges on its own. The rules differ by package, by update type
and by cluster. Read `.renovaterc.json5` and its presets for the package and the folder at hand.
They win over anything in this skill.

- An update that merges on its own waits until every required check is green. Your
  `Kritika / Review` status is one of those checks. For these PRs, the review is the last look
  before the merge.
- A package that is held back carries a ⛔ or ⚠️ note in its PR body that says why.
- `groupName` rules make one PR move several packages. Cover each package.

If a label or a title does not agree with these rules, add a note.

## A change under `kube/`

When a chart version or the values of a HelmRelease change, render the HelmRelease with flate.

### Rendering with flate

The checkout has no git history, so you can render only the new version, not a diff. Render from
the repo root. Give flate the ignore file of the cluster, so that it sees only the folders that the
Flux artifact of that cluster holds:

```
flate build hr <name> -n <namespace> --path . --krmignore .kritika/artemis.krmignore --no-progress
flate build hr <name> -n <namespace> --path . --krmignore .kritika/frostlink.krmignore --no-progress
```

For a change under `kube/base/` or `kube/components/`, render it on both clusters.

The two `.kritika/*.krmignore` files copy `FLUX_ARTIFACT_IGNORE` from
`kube/clusters/<cluster>/mise.toml`. If a pull request changes that value, it must update the
matching krmignore file too. A mismatch is a finding.

- A failure that the change causes is a finding on the changed line: a value that the chart schema
  rejects, or a template that errors on the values of this repo.
- A failed input that the change does not touch, or a source that flate failed to fetch, says
  nothing about the change.
- A render is an offline estimate. It leaves out CRDs and Secrets, and its templates see the
  Kubernetes version bundled with flate, not the version of the cluster.
- If the output is too long, drop kinds with `--skip-kinds ConfigMap,Service`.

### Exposure here

The question is not whether this repo sets the old thing. It is whether anything here depends on
it. Search `kube/` for:

- A label key or value: whatever selects on it. Look at `matchLabels` and `selector` fields of
  monitors, network policies and disruption budgets, and at label matchers in rules and dashboards.
- A resource name: whatever refers to it. Look at route backends, cluster DNS names
  (`<name>.<namespace>.svc.cluster.local`), selectors, and the Flux `dependsOn` and `healthChecks`.
- A value, flag or CRD field: the HelmRelease `values`, `valuesFrom` and `postRenderers`, kustomize
  patches, and the custom resources that other apps create from the CRDs of the dependency.

An app that you configure in its own UI keeps that configuration on its volume, not in git. A
search of this repo proves nothing about it. Say that you did not verify it.

Before you suggest a rename or a new value, make sure that it is right. Read it in the upstream PR
or in the chart template at the new tag. If you cannot, make it a check to do after the merge, not
an edit.

Anchor a finding to the changed line in the diff. Name the dependent file and line in its text.

## A change under `terraform/`

Each folder under `terraform/stacks/` is one OpenTofu stack. Validate every stack that the pull
request changes. `tofu validate` checks the configuration against the provider schema. It needs no
state and no credentials:

```
tofu -chdir=terraform/stacks/<stack> init -backend=false -input=false
tofu -chdir=terraform/stacks/<stack> validate
```

A failed validate is not always caused by the change. Before you report it as a finding:

1. Download the same stack from `main` with
   `curl -s https://git.dcunha.io/Exikle/home-infra/raw/branch/main/terraform/stacks/<stack>/<file>`
   for each `.tf` file and for `.terraform.lock.hcl`.
2. Run the same two commands on that copy.
3. If `main` fails with the same errors, the errors are older than this pull request. Do not report
   them as a finding on this change. Name them in the summary as a problem that `main` already
   has, with the error count.
4. If only the pull request fails, report each new error as a finding on the line that causes it.

A provider bump that moves a resource schema also changes what `tofu plan` does against the live
system. You cannot run a plan, because it needs credentials. Say that you did not check the plan.

## What a check proves

- Write an inference out, and only one that the evidence carries. A render that succeeds proves
  that the tag exists and that the values fit its schema.
- Check a version requirement against the version that this repo pins. A pin in git does not prove
  that every node runs it. Say that the line rests on the pin.
- Put the evidence in the claim: the value you found and the file it came from, or the source that
  says so.
- What the repo cannot show is not a check. Say what you did not verify, and what to look at
  after the merge.

## The confidence score

A second model scores the review. It reads the description, the diff, your findings and the
sources you list, but no tool output. A release-note entry that no checked line covers lowers the
score.

For an update, give each entry under the breaking changes and upgrade notes of the release, and
each step that the upgrade guide names, a checked line of its own. This includes an entry that
touches nothing here. Name the entry, then say why it does not apply or what it changes.

## How to write

The reader skims on a phone. Write less.

- One short sentence per bullet, in plain words. One fact per sentence.
- A checked line names the entry and the result, nothing more. For example: "Postgres v12
  migration: additive, no config key here changes."
- Do not restate the diff, the version numbers, or what you read. The sources list says what you
  read.
- A finding says what breaks and where, in two sentences at most.

---
name: kubesearch
description: Find real-world HelmRelease examples for an app by searching kubesearch.dev and other home-ops repos, then adapt the best match to this cluster's conventions. Use for "find examples for X", "how do others deploy X", "search kubesearch for X", or when deploying an unfamiliar app with no obvious reference. Covers Artemis and Frostlink.
compatibility: Requires outbound network access. It curls the static JSON of kubesearch.dev directly, with no MCP server and no API key. Read-only; it produces a manifest to adapt, it does not apply anything.
---

# Skill: Kubesearch — Find Home-Ops Examples

This skill searches [kubesearch.dev](https://kubesearch.dev) for real HelmRelease examples from
other home-ops clusters. Then it adapts the best example to the home-infra conventions.

For Frostlink, adapt to `.agents/instructions/frostlink.md` as well as the shared conventions.
`frostlink.md` wins where they differ. Frostlink uses an inline HTTPRoute on `external-gateway`
and the `openebs-zfs` StorageClass. Its database rules are in `frostlink.md` § Database and
cache.

The search runs over other people's repos, so the search paths in this skill use their layout
(`<their-repo>/kubernetes/apps`), on both clusters. Our own path (`kube/clusters/<cluster>/apps`)
does not exist in their repos.

kubesearch.dev indexes repos on GitHub and GitLab that carry the tag `k8s-at-home` or
`kubesearch`. Its search field is client-side JavaScript that loads static JSON files. This skill
does the same thing directly.

## Step 1: Identify the Query

Decide which app name to search for (for example `sonarr`, `paperless-ngx`, `immich`). If you are
in the middle of a task, such as deploying an app, the query is the name of that app or chart.

## Step 2: Search kubesearch.dev

Run the search script with the app name. It finds the last data chunk, downloads every chunk, and
prints the top 15 matches as `stars | name | repo | url` (substring match on the name):

```bash
bash .agents/skills/kubesearch/search.sh <app-name>
```

Read this coverage limit before you trust a result of 0. The `/hr/` dataset only reliably covers
charts that come through a `HelmRepository`. It indexes HelmReleases that use
`chartRef: OCIRepository` only partly. An infrastructure chart can return zero hits here while
dozens of repos run it on GitHub. For an infrastructure or storage chart, skip this step and go
straight to GitHub code search.

If there are 0 results, kubesearch does not index the app. The app is less common, or it does not
carry the `k8s-at-home` tag. Fall back to GitHub through MCP:

Use the `github_search_code` tool of the ops tier with the query:
`<app> filename:helmrelease.yaml path:kubernetes/apps`

Rank the results in this order:

1. Highest star count (kubesearch sorts this naturally)
2. Well-known repos: `onedr0p/home-ops`, `gavinmcfall/home-ops`, `bjw-s/home-ops`, `drag0n141/home-ops`
3. `path` contains `<their-repo>/kubernetes/apps` (home-ops layout)

## Step 3: Fetch the Top Result

Take the owner/repo and the path from the chosen URL. Then fetch the file through MCP:

Use the `github_get_file_contents` tool of the ops tier with `owner`, `repo`, and `path` from the
result URL.

If the first result looks incomplete, fetch one or two more. A result is incomplete if it is a
stub, a `.yaml.j2` template, or a file that refers to other files.

## Step 4: Present and Adapt

Show the fetched YAML, and give the source URL. Find the key patterns:

- Image: repository and tag or digest
- Environment variables: the app-specific env vars to carry forward
- Ports: the HTTP port number
- Persistence: mount paths and PVC usage
- Secrets: which env vars come from secrets
- Security context: `runAsUser`, `readOnlyRootFilesystem`, and the other fields
- Database and cache dependencies: note any `dependsOn: dragonfly-cluster`, `mariadb`, or a per-app
  Postgres. You map all of them onto our shared `database` namespace (see below)

Adapt the result to the home-infra conventions:

| Theirs                                  | Artemis equivalent                                                                                                                                                                                                    |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HelmRepository` + `chart:`             | Standalone `OCIRepository` → `oci://ghcr.io/bjw-s-labs/helm/app-template` at the current fleet tag (`grep -h 'tag:' kube/clusters/artemis/apps/*/*/app/ocirepository.yaml \| sort \| uniq -c \| sort -rn \| head -1`) |
| Any `TZ:` env var                       | Remove it. k8tz sets the timezone for the whole cluster                                                                                                                                                               |
| `secretRef` / `envFrom`                 | `ExternalSecret` via `onepassword-connect` ClusterSecretStore                                                                                                                                                         |
| `Ingress`                               | `HTTPRoute` inline in helmrelease values via `internal-gateway` (LAN) or `edge-gateway` (public)                                                                                                                      |
| `dependsOn: mariadb` / per-app Postgres | Shared CNPG cluster via `postgres-rw`. Add `../../../../components/postgres/app` and the `APP: *app` substitution (see `postgres-dragonfly.md`). `PG_APP` is only an optional override of `APP`                       |
| `dependsOn: dragonfly-cluster` / Redis  | Shared Dragonfly at `dragonfly.database.svc.cluster.local:6379`                                                                                                                                                       |
| Any namespace                           | Use the namespace that the user picked for this cluster                                                                                                                                                               |

If the source already uses `app-template`, keep its `controllers`, `containers` and `persistence`
structure. Change only the image and the secrets pattern.

## Common Issues / Gotchas

- `.yaml.j2` results are Jinja templates (gavinmcfall uses them). Their values are still useful.
  Ignore the outer template syntax.
- You can copy pinned digest tags (`image@sha256:...`). Keep the digest. This repo pins every
  image (`.agents/skills/modules/image-pinning.md`).
- Multiple instances (for example Sonarr ×3): the search returns all variants. Read the name field
  (for example `sonarr-anime`, `sonarr-4k`).
- App not in kubesearch: kubesearch often does not index less common apps (for example Pelican
  Panel). Fall back to GitHub search.
- kubesearch data staleness: the chunks update daily, so a very new app often does not appear yet.

---
name: kubesearch
description: Find real-world HelmRelease examples for an app by searching kubesearch.dev and other home-ops repos, then adapt the best match to this cluster's conventions. Use for "find examples for X", "how do others deploy X", "search kubesearch for X", or when deploying an unfamiliar app with no obvious reference. Covers Artemis and Frostlink.
compatibility: Requires outbound network access. It uses the public kubesearch MCP server (no API key) and falls back to the static JSON of kubesearch.dev. Read-only; it produces a manifest to adapt, it does not apply anything.
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
`kubesearch`. Its developer runs an MCP server over the same index at
`https://beta.kubesearch.dev/mcp`. The server is registered as `kubesearch` in `.mcp.json` and
`opencode.json`. It needs no key. Use it first. It answers a search in under a second. The old
path (Step 2b) takes about 20 seconds and searches only names.

The old path stays as a fallback until the review in #3457 (due 2026-12-15). If the MCP server
fails or returns nothing useful during that time, note it in #3457.

## Step 1: Identify the Query

Decide which app name to search for (for example `sonarr`, `paperless-ngx`, `immich`). If you are
in the middle of a task, such as deploying an app, the query is the name of that app or chart.

## Step 2a: Search the kubesearch MCP server

Tool names carry a server prefix that changes per client. Match on the tool part of the name.

1. Call `search_releases` with `query` set to the app name. It matches the release name, the
   chart name and the chart source URL. Each result is one group (for example "sonarr on
   app-template") with an `id`, a `deployment_count` and `top_repos` ranked by stars. Each
   entry in `top_repos` has a `file_url` and a `source_kind` (`HelmRepository` or
   `OCIRepository`).
2. Call `get_release` with the `id` of the best group. The default summary lists the Helm values
   that most deployments set, and example configurations.
3. To read the values of one repo, call `get_release` again with `view: "values"`, the `repo`,
   and the `value_paths` from the summary.
4. To read a full manifest, call `repo_clone` with the `owner/repo`, then `repo_read_file` with
   the path from `file_url`. Call `repo_cleanup` with the handle when you finish.

Other tools help with a narrower question:

- `grep_values` finds a key or a value across every indexed values document (for example
  `valuesFrom`, or an env var name).
- `search_images` finds a container image, the tags that repos use, and the repos that use it.
- `repo_grep_all` searches the manifests of the ten most-starred repos in one call.
- `status` reports the date of the crawl and the size of the index.

The tools read only the stored manifests. They do not resolve `valuesFrom` files, Secrets or
ConfigMaps. If you have the manifest, go to Step 4. If the MCP server does not answer, or it
finds nothing, go to Step 2b.

## Step 2b: Fallback, search the static JSON of kubesearch.dev

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

## Step 3: Fetch the Top Result (fallback only)

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

# Cortex MCP Fleet — per-server reference

This file holds everything that the `cortex` MCP manifests used to say in comments. Manifests
under `kube/clusters/artemis/apps/cortex/` carry no prose (`yaml-conventions.md`
§ No Comments in Manifests). The reasons live here.

agentgateway replaced LiteLLM on 2026-10-26. The gateway also serves model traffic. This file
covers only the MCP half.

## Layout

| Piece                | Where                                                                              |
| -------------------- | ---------------------------------------------------------------------------------- |
| Controller + CRDs    | `kube/clusters/artemis/apps/agentgateway-system/agentgateway/{crds,app}`           |
| Gateway, models, MCP | `kube/clusters/artemis/apps/cortex/agentgateway/{gateway,models,mcp}`              |
| MCP server workloads | `kube/clusters/artemis/apps/cortex/mcp/app/<member>` (Kustomization `mcp-servers`) |

The controller has its own `agentgateway-system` namespace, because it is an operator for the
whole cluster (`cluster-conventions.md` § App Directory Structure). The gateway and the workloads
are in `cortex`. `ls kube/clusters/artemis/apps/cortex/mcp/app/` lists the fleet. The shape is the
"fleet" shape in `app-structure.md`. HelmRelease and Service names are `mcp-<name>`. The one
exception is `victoria-logs-mcp`.

## The shape of the thing

`mcp/agentgatewaybackend.yaml` holds three `AgentgatewayBackend` objects: `mcp-ops`,
`mcp-general` and `mcp-agent`. Each one is a list of `targets`, and each target points at a
Service. One `HTTPRoute` (`agentgateway-mcp`) maps a path to each backend: `/ops/mcp`,
`/general/mcp` and `/agent/mcp`. This command lists the targets of each tier:
`grep -n 'name:' kube/clusters/artemis/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml`.

The `agent` tier is for hermes only. It is absent from every client registration file on purpose
(`memory-config.md`). It carries only the tools that the hermes skills call, because each tool
schema costs tokens on every turn of every run. If you add a target to `mcp-agent`, hermes pays for
that schema on every turn. Why, and what it costs: `.agents/references/hermes.md` § Cost, which
wins.

A route-level `AgentgatewayPolicy` guards each route. The `apiKey.user_id` must be equal to the
identity of the tier (`ops`, `general` or `hermes`). The request must also have no
`Authorization` header. The gateway-wide policy `agentgateway-auth` (Strict) checks the key. The
per-route policy decides which key can reach which tier.

### Clients must send the key as `x-api-key`

agentgateway forwards client headers to the MCP server. For that reason, each backend removes
`x-api-key` before it forwards the request. A backend cannot do the same for `Authorization`. If
it removed that header, it also removes the upstream token of each target. forgejo, github,
context7 and sparkyfitness get their tokens through `policies.auth.secretRef`. So the route policy
refuses `Authorization` instead. If a client sends `Authorization: Bearer <key>` to an MCP path,
the gateway refuses the request.

The models route has the matching rule. The gateway reads the key through a CEL expression, and
that expression removes no header. So the `agentgateway-models` policy removes `x-api-key` before
the request goes upstream. Without that policy, a client that sends `x-api-key` to an
OpenAI-format model gives its gateway key to opencode.ai. Anthropic-format models overwrite the
header themselves.

### Tool names

Tools are `<target>_<tool>`, with `prefixMode: Always`. Claude Code shows them as
`mcp__ai-<tier>__<target>_<tool>`, for example `mcp__ai-general__victoria-logs_query`. The
gateway uses `_` as the separator, so a target name must contain no `_`. That is the reason for
`victoria-logs` and not the old `victoria_logs`.

Target names are a fixed public interface. If you rename a target, you break every skill, runbook
and habit that names one of its tools, and nothing tells you. Do not rename a target to make it
tidy. The old LiteLLM form was `mcp__litellm-<tier>__<alias>-<tool>`. Anything that still uses
that form is out of date.

### Upstream sessions: `sessionRouting: Stateless`

Every backend sets `spec.mcp.sessionRouting: Stateless`. With this value, the gateway opens a new
session on each target for each request. It sends `DELETE` when the response is complete (v1.6.0
`serve_stateless`). The default is `Stateful`. Under `Stateful`, the 30-minute idle reaper of the
gateway removes only its own entry and sends nothing upstream. So every stateful server keeps every
session that it ever got, and its memory grows without limit. The CRD has no field for a session
time limit. The cost of
`Stateless` is one more upstream round trip for each call. A client `GET` or `DELETE` gets `405`,
and the MCP spec permits that.

### One replica, on purpose

`agentgatewayparameters.yaml` sets one replica. The token rate limit of each key
(`models/agentgatewaypolicy.yaml`, `rateLimit.local`) is counted in each replica. A second replica
doubles the limit of every key. Do not scale it, and do not add an HPA.

### The forgejo allow-list

forgejo registers a few hundred tools, with `FORGEJO_DISABLED_AREAS` set to turn off
actions, organizations, packages and repo-settings. To see the tag, run
`grep tag: kube/clusters/artemis/apps/cortex/mcp/app/forgejo/helmrelease.yaml`. The
`policies.mcp.authorization` Deny rule on the backend in `agentgatewaybackend.yaml` permits 37 of
them. The 37 tools keep the issue tracker, Renovate PR triage and code reads. The rule removes
these tools:

- All `admin_*` tools.
- Org, team and user management, notifications, templates and social endpoints.
- The file create, update and delete calls. These calls make commits that the instance key
  signs. That goes around the two-identity signing model in `commit-style.md`.

The list keeps `merge_pull_request` and `update_pr_branch`. Both also make server-side commits that
the instance key signs. That fits the signing model only for Renovate PRs, which are
instance-signed by design. Never use them on your own work (`commit-style.md` § Two-identity
signing model wins).

The rule applies when a tool is called. A client that is already connected keeps its cached tool
list until it connects again. So a running session shows an older tool list than the
configuration. To test the filter, call a blocked tool and read the error. Do not trust the list
that the session shows. A hand-made `initialize` + `tools/list` probe is also not reliable. Use a
real MCP client.

## Adding an MCP server

1. If the server needs a workload, add a member under
   `kube/clusters/artemis/apps/cortex/mcp/app/<name>/`. Copy a sibling, and list it in
   `mcp/app/kustomization.yaml`. Name the Service `mcp-<name>`.
2. Add a `targets` entry to the correct backend or backends in `mcp/agentgatewaybackend.yaml`.
   The target `name` becomes the public tool prefix. Choose it one time, and use no `_`.
3. If the server needs an upstream token, add `policies.auth.secretRef` on the target. Add an
   ExternalSecret in `agentgateway/mcp/externalsecret.yaml`. Never depend on the client to send
   the token.
4. If you add a new tier, you need more:
    - A `backendRefs` rule in `httproute.yaml`.
    - A route-level policy in `agentgatewaypolicy.yaml`.
    - An API key in the 1Password item `agentgateway`. `gateway/externalsecret.yaml` makes it a
      labelled Secret.
    - An entry in every registration file in `memory-config.md`.
5. Test with a real client, and count the tools. The backends are `failureMode: FailOpen`. So if
   a target is down, the gateway skips it with no message, and the tier answers with fewer tools.

From the workstation, clients reach a tier at `https://ai.dcunha.io/<tier>/mcp`. In the cluster,
they reach it at `http://agentgateway.cortex.svc.cluster.local:4000/<tier>/mcp`.

## Per-server notes

### arr (`mcp-arr`, target `arr`, general)

<https://github.com/aplaceforallmystuff/mcp-arr>. It runs the official GHCR image, not npx. The
project publishes to npm by hand, and npm lags far behind the tags.

It has 48 tools. The seven `trash_*` TRaSH-guide helpers have no upstream switch to turn them off.
So the `mcp-general` backend denies them, and 41 tools are left. Health is `GET /health`.

On 2026-10-26, the team examined one server to replace both arr and Seerr. `bardesss/arr-mcp` is
the only usable candidate, and it needs its own configuration volume and UI. The team kept two
servers.

### context7 (target `context7`, general)

It is a hosted endpoint at <https://mcp.context7.com/mcp>. It has no container and no workload,
so there is nothing to harden. The gateway sends the key as the upstream token of the target, with
an explicit TLS `sni`. It has 2 tools.

### kubesearch (target `kubesearch`, general)

It is a hosted endpoint at <https://beta.kubesearch.dev/mcp>. The developer of kubesearch.dev
runs it over the same crawl index. It needs no key, so the target has only the TLS `sni`. It has
11 tools. The `kubesearch` skill uses it first. #3457 decides on 2026-12-15 if the old search
path of the skill can go. If the server moves off the `beta.` host, change `host` and `sni`.

### trawl (target `trawl`, general)

The app itself serves MCP at `/mcp` on its own port 8191, in `media`. It has no MCP workload in
`cortex`. Trawl turns the route on only when `MCP_ENABLED` is `"true"`, so the HelmRelease sets
it. MCP in trawl has no authentication. Upstream says that you must keep it on a private
network. Do not give trawl a public route. The gateway key of the general tier is the only gate.

### forgejo (`mcp-forgejo`, target `forgejo`, ops)

<https://code.squarecows.com/SquareCows/forgejo-mcp>, package `@ric_/forgejo-mcp`. The image is
ours, `git.dcunha.io/exikle/forgejo-mcp`. `Exikle/containers` (`apps/forgejo-mcp`) builds it from
the npm release, and it runs upstream `dist/http.js`. Renovate bumps the npm version there.

Do not wrap `dist/http.js` again. Upstream keeps one transport for each session, with an LRU
limit. A local wrapper once had no limit and leaked memory.

We override two upstream defaults, `PORT` and `RATE_LIMIT_MAX`. `PORT` defaults to 3000. The
upstream default for `RATE_LIMIT_MAX` is 100 requests a minute for each client IP. Every request
comes from the one IP of the gateway. Under stateless routing, each tool call makes four requests.
So we set the limit to 6000. Health is `GET /health`.

### flux (`mcp-flux`, target `flux`, ops and agent)

<https://github.com/controlplaneio-fluxcd/flux-operator>. It comes from the same vendor as the Flux
Operator that this cluster already runs. Keep the two versions in step. Compare
`grep -n 'repository\|tag' kube/clusters/artemis/apps/cortex/mcp/app/flux/helmrelease.yaml` with
the image of the `flux-operator` Deployment.

It runs `serve --transport http --port 8080 --read-only --mask-secrets`. `--mask-secrets` defaults
to true. We pass it explicitly, so the intent stays if the upstream default changes.

`--read-only` leaves 10 tools, not the 15 that upstream documents:
`get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_events`,
`get_kubernetes_logs`, `get_kubernetes_metrics`, `get_kubernetes_resources`, `read_flux_doc`,
`search_flux_docs`, `trace_kubernetes_resource` and `diff_kubernetes_manifest`. The flag turns off
the five tools that change the cluster: `reconcile_flux_resource`, `suspend_flux_reconciliation`,
`resume_flux_reconciliation`, `apply_kubernetes_manifest` and `delete_kubernetes_resource`. That
is the purpose of the flag, because `AGENTS.md` rule 2 forbids exactly those actions through MCP.
`diff_kubernetes_manifest` stays in read-only mode. It reads and compares. It does not apply.

It uses its own ServiceAccount `mcp-flux-sa` (`flux/rbac.yaml`), bound to the existing `mcp-k8s`
ClusterRole. It does not use the default ResourceSet of the chart, which grants `cluster-admin`.
The image is distroless and runs as uid 65532, not 1000. For that reason, its
`podSecurityContext` is different from most of the fleet.

It overlaps `k8s` on generic resource reads. The team accepted that, because nothing else provides
`search_flux_docs` and `get_flux_instance`. It has no health route, so its probes are TCP.

### github (`mcp-github`, target `github`, ops)

<https://github.com/github/github-mcp-server>, official. The `http` subcommand serves Streamable
HTTP at the server root (`/`), not at `/mcp`. That is the reason for `path: ""`. The team
confirmed this against `docs/streamable-http.md` and the hosted `api.githubcopilot.com/mcp/`
convention.

`GITHUB_READ_ONLY=true` is set. This repo mirrors to GitHub, and an agent never writes there.

In `http` mode, the server takes the token only from the `Authorization` header of the request.
The gateway adds that header. Only `stdio` mode reads `GITHUB_PERSONAL_ACCESS_TOKEN`. So the pod
mounts no token. The ExternalSecret stays, because the gateway's `secretRef` reads `github-mcp`.
It has no health route. `/` returns 401, so the probes use the static
`/.well-known/oauth-protected-resource`.

### grafana (`mcp-grafana`, target `grafana`, general)

<https://github.com/grafana/mcp-grafana>, official. The default transport is stdio, so it needs an
explicit `-t streamable-http`.

`-allowed-hosts` is required. It must include the service FQDN without a port. Its default is the
loopback variants of `--address`. agentgateway sends the target host without a port as the `Host`
header, so `mcp-grafana.cortex.svc.cluster.local` must be in the list. If it is not, the server
refuses every request with `403 Forbidden` before the request gets to the MCP handler. At the
same time, the pod stays `1/1` Running and the backend reports healthy. The same check guards
`/healthz`. The kubelet sends the pod IP as `Host`, so the probes carry `Host: mcp-grafana:8000`.

We set `-disable-write`, and `-disable-*` for Asserts, Incident, OnCall and Pyroscope. These are
the only groups in the default `-enabled-tools` list that this cluster does not run. Athena,
ClickHouse, CloudWatch, Elasticsearch, Graphite, InfluxDB, Quickwit, Snowflake, Assistant and
Agent o11y are off by default. Their flags did nothing, so the team removed them.

Make its `GRAFANA_SERVICE_ACCOUNT_TOKEN` in Grafana, under Administration → Service Accounts →
Add service account token.

### ha (`mcp-ha`, target `ha`, ops)

<https://github.com/homeassistant-ai/ha-mcp>. The default image CMD speaks stdio only.
`ha-mcp-web` is the HTTP entrypoint of the project (`fastmcp-http.json`: transport http,
`0.0.0.0:8086`, path `/mcp`).

It has 78 tools, and upstream ships the fix. `ENABLE_TOOL_SEARCH=true` replaces the full catalogue
with about four proxy tools. The upstream `.env.example` says that it "Reduces idle context from
~46K to ~5K tokens." It is set. This was the largest context saving available in the fleet.

The first request after a restart is slow, because ha-mcp builds its tool-search index on first
use. agentgateway has a hidden 10 s default timeout for MCP upstream calls. So every target needs
`policies.http.requestTimeout: 300s`. If a tier shows a 500 with `upstream call timeout` at exactly
10 s, a target has no `requestTimeout`.

Upstream publishes semver image tags (`release-publish.yml`). So the pin is `<version>@sha256`,
and Renovate tracks it.

`ha-mcp-web` serves a settings page with no authentication at `/mcp/settings`.
`HA_MCP_DISABLE_SETTINGS_UI=true` turns it off. `/healthz` exists only with `MCP_HEALTHZ=true`.

Make its `HA_TOKEN` in Home Assistant, under Profile → Long-Lived Access Tokens → Create Token.

### k8s (`mcp-k8s`, target `k8s`, ops and agent)

<https://github.com/containers/kubernetes-mcp-server>. Auth is the in-cluster ServiceAccount
`mcp-k8s-sa`. The server finds it automatically at runtime. `--port` starts Streamable HTTP at
`/mcp` and SSE at `/sse` together. It and `flux` are the only two members with
`automountServiceAccountToken: true`. They are the only members that need an identity on the API
server.

The RBAC has no `secrets` rule. In the Kubernetes API, `list` returns full objects, `.data`
included. So a `secrets: list` grant gives full read access to every credential, from an LLM tool
endpoint. There is also no `patch` on `helmreleases`, `kustomizations` or workloads (`AGENTS.md`
rule 2: no cluster changes through MCP). The live rule set is
`kubectl get clusterrole mcp-k8s --context artemis -o yaml`. `hermes.md` § RBAC summarises it.

We keep these writes on purpose, as operational actions and not configuration changes:
`pods/exec: create`, `pods: delete`, `jobs: delete`, `events: create` and `*/scale`. Read-only
access to `fluxcd.controlplane.io` lets the ops tier look into its own control plane.

`disable_destructive = true` (in `resources/config.toml`) enforces the rule "never apply cluster
changes through MCP" in the server itself. It also removes `pods_exec` and `resources_scale`,
which carry `destructiveHint=true`. So the exec and scale grants above are not in use today. To
get them back, replace `disable_destructive` with an explicit `disabled_tools` list.
`disabled_tools` also removes four tools that cannot work here:

- `pods_run`, because there is no `pods: create`.
- `nodes_log` and `nodes_stats_summary`, because there is no `nodes/proxy`.
- `projects_list`, because it is for OpenShift.

`denied_resources` blocks Secret as a second wall behind RBAC. It has 10 tools. Health is
`GET /healthz`.

### searxng (`mcp-searxng`, target `searxng`, general and agent)

<https://github.com/ihor-sokoliuk/mcp-searxng>. `MCP_HTTP_HOST` must be `0.0.0.0`. Its default is
127.0.0.1 only, and the gateway pod cannot reach that address. It has 4 tools. The in-cluster
`searxng` app backs it, not a public instance. Health is `GET /health`.

### seerr (`mcp-seerr`, target `seerr`, general)

<https://git.dcunha.io/Exikle/seerr-mcp>, a Go rewrite of upstream overseerr-mcp v2.3.1 on the
official go-sdk. The image is ours, `git.dcunha.io/exikle/seerr-mcp`. It speaks MCP 2026-07-28 and
the legacy protocol versions. It is stateless over HTTP (no sessions).

`ALLOWED_ORIGINS` is `*`. The gateway forwards the `Origin` header of the client, and the
gateway's CORS SecurityPolicy does the origin check.

The env var is `SEERR_URL`, not `SEERR_HOST`. If you set the wrong one, the server breaks with no
message.

It has 8 tools. Six are ported from upstream. The other two are `seerr_find_api` and
`seerr_call`. `seerr_find_api` gives areas, browse, search and details over all of the Seerr
API. `seerr_call` runs any operation. `seerr_call` masks secrets in replies. On a write, it
puts a secret back only into the same key in the same settings area. It refuses the key-rotating
`POST /settings/main/regenerate`, `POST /settings/initialize` and `/auth/*`. Health is
`GET /health`. The app and its tools are `seerr`, not "Jellyseerr". See `media-stack.md`.

### sparkyfitness (target `sparkyfitness`, general)

It has no workload. SparkyFitness serves MCP in its own process at `POST /mcp` on its server
Service. So the target points at `sparkyfitness-server.default.svc.cluster.local:3010`.

Auth is an API key for each user. Make it in the app, under Settings → Developer & Integrations →
API Key Management (`/settings?section=api-settings`). It is stored as `MCP_API_KEY` on the
`sparkyfitness` 1Password item. Postgres RLS limits every tool to the user of that key.
`API_ENCRYPTION_KEY` on the same item is the server's key for encryption at rest, not a bearer
token. If you send it as a token, the server returns 401.

### victoria-logs (`victoria-logs-mcp`, target `victoria-logs`, general and agent)

<https://github.com/VictoriaMetrics/mcp-victorialogs>, official. It has 13 tools.

The workload is `victoria-logs-mcp`, while every sibling is `mcp-<x>`. The team kept this name on
purpose, because a rename means that the Deployment and the Service are made again. Do not rename
it to make it tidy.

The embedded bleve index is an in-memory keyword index over its docs, not a vector DB. Most of its
memory is that index. Before you change the 256Mi limit, run
`kubectl top pod -n cortex -l app.kubernetes.io/name=victoria-logs-mcp --context artemis`. Health
is `/health/liveness` and `/health/readiness`.

## Fleet-wide

### The CORS SecurityPolicy is load-bearing

`gateway/securitypolicy.yaml` exists for MCP clients that run in a browser (VS Code, web UIs). It
must continue to expose `Mcp-Session-Id`. A client uses that header to track a stateful
streamable-http session. If you remove it, only those clients break, with no message. Every
server-side caller continues to work.

### Security posture

Every member that runs a container has these settings:

- `runAsNonRoot`, with uid/gid 1000. `flux`, `ha` and `seerr` run as uid/gid 65532.
- `allowPrivilegeEscalation: false`.
- `capabilities: drop: [ALL]`.
- `readOnlyRootFilesystem: true`, with a `/tmp` emptyDir.
- `automountServiceAccountToken: false`. `k8s` and `flux` are the exceptions.

`grep -rn runAsUser kube/clusters/artemis/apps/cortex/mcp/app` shows the uid of each member.

Every member has liveness, readiness and startup probes (startup: 5 s period, 30 tries). The
section of each server above gives its paths.

### Tool-surface budget

Every tool schema costs tokens on every turn. That is the reason that the team counts tools. The
counts for each server above are the numbers to know. To measure a tier, run this command from a
pod that has the key of the tier. Use `x-api-key`, not `Authorization`:

```bash
curl -s -X POST "http://agentgateway.cortex.svc.cluster.local:4000/<tier>/mcp" \
  -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

That command proves the handshake. A full `tools/list` needs the `Mcp-Session-Id` that the
`initialize` reply returns. If you need the byte count, use a real MCP client.

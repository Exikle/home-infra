# Hermes — home-infra

This file is the operational reference for the Nous Research hermes-agent that runs in `cortex`.
The team deployed it on 2026-08-14. The team ported it from
[eleboucher/homelab](https://git.erwanleboucher.dev/eleboucher/homelab). The port is finished, and
this file does not describe how to do it again.

The image tag is in the HelmRelease
(`grep -n 'repository:' -A2 kube/clusters/artemis/apps/cortex/hermes/app/helmrelease.yaml`).
Statements marked "(checked on v0.22)" were not checked again on a later image.

Before you change the models, the cron cadence or the MCP tier, read § Cost. hermes is the
largest consumer of inference in the cluster. The OpenCode Go allowance is a hard monthly limit,
not a bill.

The manifests are in `kube/clusters/artemis/apps/cortex/hermes/`. The skills that ship from git
are in `kube/clusters/artemis/apps/cortex/hermes/app/skills/`.

---

## What it is

hermes is one Deployment with `strategy: Recreate`. It has one container (`app`,
`nousresearch/hermes-agent`) on an RWO PVC. It is the agent gateway. It serves the dashboard on
`:9119`, the Webapp on `:9120` and health on `:8642`, and it runs cron.

Three init containers run in this order:

1. `init` resets `/opt/data/config.yaml` to the version stamp only, and resets `/opt/data/.env`
   to empty (§ Config and managed scope). It deletes each local skill copy that has the same name
   as a git skill. It seeds the state directory for `cluster-health` (§ Skills). It copies the
   cron scripts from git into `/opt/data/scripts/` (§ Cron jobs).
2. `install-memini` installs the memini plugin at a pinned commit (§ Deps and wiring). When the
   plugin is already at that commit, the container does no network I/O.
3. `cron-reconcile` makes the cron jobs match `app/cron/jobs.yaml` (§ Cron jobs). It has
   `dependsOn` for both `init` and `install-memini`, so it always runs last. app-template orders
   init containers with a topological sort on `dependsOn`. Containers without `dependsOn` run in
   name order. That is why this container declares it.

The app runs `/opt/hermes` from the image itself. The image ships that directory root-owned and
read-only on purpose. So the agent cannot edit its own interpreter, venv or dashboard. There is no
copy of the directory and no writable source tree.

Do not bring back the retired `copy-agent-source` and `install-tools` init containers. Extra tools
come from `uvx` or `npx`, or from a derived image. They do not come from a download at runtime. A
`pip install` into the image tree fails by design.

`args` is plain `[gateway, run]`. The image registers the gateway as an s6 service next to the
dashboard (checked on v0.22). It keeps the main process alive with `sleep infinity`. With
`--no-supervise`, the main process collides with the gateway that s6 owns, and it exits 1. The pod
then stays alive only because the s6 shutdown hangs. So every rollout sends SIGKILL to the gateway
after the 120s grace period.

`$HOME` is `/opt/data`. That is the `hermes` PVC (4Gi `miroir`, `existingClaim: hermes` from
`components/kopiur/backup`). The PVC holds the home directory, the plugin, the skill library, the
cron state and the session history. For this reason `Recreate` is mandatory, because a
RollingUpdate deadlocks on Multi-Attach. For the same reason the volume has a backup.

There are two routes. Both are on `edge-gateway`, which is public through towonel:

| Hostname               | Backend port | What                  | Auth                                           |
| ---------------------- | ------------ | --------------------- | ---------------------------------------------- |
| `hermes.dcunha.io`     | `9119`       | dashboard             | pocket-id OIDC, `allowedUserGroups: app-admin` |
| `hermes-app.dcunha.io` | `9120`       | Webapp (from v0.23.0) | the same pocket-id OIDC client                 |

Authorization is in `oidcclient.yaml`.

The Webapp is the Desktop workspace in a browser tab. The `webapp:` block in `config.yaml` turns
it on. It needs `host: 0.0.0.0`, because the default `127.0.0.1` cannot receive traffic from
envoy. A host that is not loopback turns on the sign-in gate. Hermes has no mode without sign-in.

The Webapp uses the same self-hosted OIDC provider as the dashboard (the `HERMES_DASHBOARD_OIDC_*`
variables). Its callback is `<webapp.public_url>/auth/callback`, so `oidcclient.yaml` holds both
callbacks. The route rule sets `timeouts.request: 0s`, as bjw-s-labs/home-ops does. This stops
envoy from cutting long chat streams. The Webapp is single-user. A signed-in tab acts as the agent
owner.

`dashboard.trusted_proxies` is the pod CIDR (`10.42.0.0/16`). The Webapp reads the same list.
Without it, hermes ignores the `X-Forwarded-Proto: https` header from the envoy pod, and it sees
plain http. It then issues the OIDC login cookies without `Secure` or `SameSite=None`. Envoy pod
IPs change, so a CIDR is the only stable value. The network policy (§ Network policy) now lets
only the `edge-gateway` pods reach 9119 and 9120. So the wide CIDR no longer lets a random pod
spoof `X-Forwarded-*`.

### Deps and wiring

| Depends on   | Address                                         | Purpose                               |
| ------------ | ----------------------------------------------- | ------------------------------------- |
| agentgateway | `agentgateway.cortex.svc.cluster.local:4000/v1` | all inference, `AGENTGATEWAY_API_KEY` |
| memini       | `memini.cortex.svc.cluster.local:8080`          | memory, namespace `homelab/hermes`    |
| SearXNG      | `searxng.cortex.svc.cluster.local:8080`         | web search                            |
| chaski       | `chaski.observability.svc.cluster.local`        | Pushover notifications from skills    |
| Forgejo      | `git.dcunha.io` as dusk-bot                     | PRs and commits                       |

`ks.yaml` has `dependsOn` for `agentgateway-mcp`, `agentgateway-models`, `memini` and
`security/pocket-id-operator`. The first three are the gateway pieces that hermes calls. The last
one is the operator whose CRs hermes needs.

The memini plugin is the `memini-hermes` memory plugin. It reads `MEMINI_BASE_URL`, not
`MEMINI_URL`. If that variable is missing, the plugin silently uses `http://localhost:8080`. Memory
then looks enabled, but nothing is stored. After any change to the environment, search the memini
log for `handshake: namespace resolved namespace=homelab/hermes`.

The `install-memini` init container installs the plugin onto the PVC at `/opt/data/plugins/memini`
with `hermes plugins install eleboucher/memini-hermes --ref <sha> --force --yes-deps --no-enable`.
The SHA is a plain value in the script of that container. To bump the plugin, change that value.
The init container sees a different commit and installs again from github. So it needs egress
for that one boot (§ Network policy).

More facts about the plugin:

- `hermes plugins adopt` is not a replacement. It is not idempotent: it exits 1 when a provenance
  row exists. Also, it does not pin.
- `hermes plugins doctor memini` reports two ERRORs (`on_pre_compress` and `on_memory_write`
  hooks), even for the newest upstream release. The plugin still registers its tools and works.
- `memory.provider: memini` activates the plugin. `plugins.enabled` does not.

The memini namespace is `homelab/hermes`. `MEMINI_HOME` is `personal/exikle`, and the plugin
sends it as `X-Memini-Home`. If `MEMINI_HOME` is unset, no personal leg merges into recall. The
agent reads the shared `homelab` facts. Its own memories stay in its namespace and do not mix with
`homelab/home-infra`. See `.agents/references/memory-config.md` § Namespace Topology.

### Secrets

One ExternalSecret builds `hermes-config` from four 1Password items. It reads `forgejo`,
`agentgateway` and `hermes` with `dataFrom`, and it reads `memini` with `data`:

| Env                                   | Source                                                                               |
| ------------------------------------- | ------------------------------------------------------------------------------------ |
| `AGENTGATEWAY_API_KEY`                | `agentgateway` → `KEY_HERMES` (the hermes tier key. MCP and model calls both use it) |
| `MEMINI_API_KEY`                      | `memini` → `MEMINI_API_KEY`                                                          |
| `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` | `hermes` → `HERMES_OIDC_CLIENT_SECRET`                                               |
| `API_SERVER_KEY`                      | `hermes` → `API_SERVER_KEY`                                                          |
| `FORGEJO_PAT`                         | `forgejo` → `DUSK_BOT_CLUSTER_TOKEN` (infrastructure vault)                          |

The Secret also pulls the managed `.env` content (`/etc/hermes/.env`, § Config and managed
scope). It does this with `templateFrom` on the `env` key of `hermes-configmap`. So an edit to the
ConfigMap changes the Secret, and Reloader restarts the pod.

`API_SERVER_KEY` is also a plain `secretKeyRef` env var on `app`. Without it, stage2 sees no key
in the container environment. It then appends a generated decoy key to the user `.env` on every
boot.

`FORGEJO_PAT` belongs to dusk-bot, not Exikle. Never give hermes a token of Exikle. The commits
of hermes then show Exikle as the author.

dusk-bot is a repo admin on `home-infra`. Renovate uses the same identity. So a hermes commit and
a Renovate commit have the same author. Branch protection does not apply to admins, so the token
can merge a PR without the `Kritika / Review` check. The team keeps the admin role on purpose. For
hermes, the merge deny glob in § Autonomy posture is the only stop.

---

## Config and managed scope

The full configuration of the agent is pinned in the managed scope of Hermes. So neither the
dashboard nor the agent can change it between restarts. The source is
`hermes_cli/managed_scope.py` in the image.

| Where                                    | What                                                                   | From                                        |
| ---------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------- |
| `/etc/hermes/config.yaml` (read-only)    | every setting we own: providers, model, approvals, skills, cron, ...   | `hermes-configmap` key `config.yaml`        |
| `/etc/hermes/.env` (read-only, mode 400) | `OPENAI_BASE_URL`, `API_SERVER_KEY`                                    | Secret `hermes-config` key `env` (rendered) |
| `/opt/data/config.yaml` (PVC)            | `_config_version: 53` and nothing else, rewritten by `init` every boot | `hermes-configmap` key `user.yaml`          |
| `/opt/data/.env` (PVC)                   | empty, truncated by `init` every boot                                  | -                                           |

How the layers combine:

- The managed file deep-merges over the user file per leaf, after `${VAR}` expansion. So a user
  value cannot hide a managed value.
- Dicts merge key by key.
- A list (`skills.disabled`, `approvals.deny`, `fallback_providers`) is one leaf. The merge
  replaces it whole.
- Hermes loads the managed `.env` last, with override. So it wins over the user `.env` and over
  the container environment.
- Hermes reads both managed files from `/etc/hermes` (or `$HERMES_MANAGED_DIR`). If the directory
  is missing, there is no managed scope.
- If a managed file does not parse, Hermes ignores it and prints a warning (fail-open). So after a
  change, run `hermes doctor` and read its output.

What a pinned key does:

- `hermes config set` or `unset` on a pinned key exits 1 with "managed by your administrator".
  `hermes config set` on a pinned env name is refused in the same way.
- The dashboard saves through `save_config`. That function drops pinned leaves and prints a note
  to stderr instead of failing. The edit looks successful, but the effective value does not
  change.
- An agent that writes `/opt/data/config.yaml` directly also loses. The managed leaf wins on the
  next load. The team tested this with a user file that held `model.default: evil/model` and
  `approvals.mode: off`. Both keys still read the git values.
- A key that is not in the managed file is not pinned. An unlisted key falls back to the Hermes
  default plus the value in the user file. So the agent can still set, for example,
  `terminal.env_passthrough`. `init` rewrites the user file to the stamp on every boot, so such a
  change lasts one pod lifetime at most. When an image bump adds a key that matters for security,
  add that key to `config.yaml` too.

Why the managed file holds the full configuration, not only the sensitive keys: the agent can
write to `/opt/data`, because it has `write_file` and a shell. With a partial managed file, every
other key stays editable until the next boot. With the full configuration, one file in git states
the whole intended configuration.

Why the user file still exists:

- `docker_config_migrate.py` and `hermes doctor` read the `_config_version` stamp only from the
  user `config.yaml` (`config_version_stamp.py`).
- If the user `config.yaml` is missing, stage2 seeds a full example configuration in its place.

Keep `_config_version` out of the managed file. `save_config` strips pinned leaves, so it removes
a pinned stamp from the user file.

To change a setting, edit `config.yaml` in `configmap.yaml`. Then land it like any other manifest
change. Reloader restarts the pod. There is no hot reload.

The files are `subPath` mounts. A directory mount over `/etc/hermes` hides two files that the
image ships there: `image-provenance.json` and `agent-browser-executable-path`. A `subPath` mount
never receives ConfigMap updates. That is acceptable here, because the controller carries
`reloader.stakater.com/auto`, and the pod references both `hermes-configmap` and `hermes-config`.

`$${VAR}` in the ConfigMap is the Flux escape. Hermes sees `${VAR}` and expands it from the
process environment.

Secrets stay out of the ConfigMap. The managed `.env` comes from the Secret, never from a
ConfigMap. Other keys (`AGENTGATEWAY_API_KEY`, `FORGEJO_PAT`, ...) reach the container as
`secretKeyRef` env vars, and they are not pinned. If someone writes a key to the user `.env`,
`init` empties it on the next boot.

To make sure that the managed scope works, run this command:

```bash
kubectl -n cortex exec deploy/hermes -c app --context artemis -- hermes doctor
```

It reports `Managed scope active: N config key(s), 2 env key(s) pinned by /etc/hermes` and
`Config version up to date (v<N>)`, where N is `_config_version` in the `user.yaml` key. It reports
no deprecated keys. Also, `hermes config get model.default` returns the git value.

---

## Model configuration

`config.yaml` is in `hermes-configmap` (§ Config and managed scope). The file declares eight
`opencode-go` models. If agentgateway serves a model but `providers.agentgateway.models` does not
list it, the agent cannot use that model.

The provider is declared in the `providers:` dict. The old `custom_providers:` list is a retired
store, and `hermes doctor` warns about it. `custom:agentgateway` in `model`, aliases, fallbacks
and `auxiliary` resolves to the dict key `agentgateway`.

To read the declared models, their `context_length` and their aliases, run:

```bash
grep -A20 '    models:' kube/clusters/artemis/apps/cortex/hermes/app/configmap.yaml
grep -A25 'model_aliases:' kube/clusters/artemis/apps/cortex/hermes/app/configmap.yaml
```

- The default model is `opencode-go/minimax-m3`.
- `model.context_length` is the compaction trigger and nothing else. Upstream never uses it to
  truncate a request. It is 262144. Compaction does not start at `compression.threshold` (0.5)
  times that value. The image raises the ratio to 0.75 for any window under 512K tokens (checked
  on v0.22). So the real trigger is 196,608 tokens. The team measured this with the compressor
  functions of the image, run in the pod.
- The real window of minimax-m3 is `1000000`. If you set `model.context_length` too high, a runaway
  session grows very large before anything trims it. If you set it below the real window, the only
  cost is earlier compaction. You never get a provider error.
- The pin also logs a startup warning that the provider advertises a larger window. That warning
  is expected. For an absolute cap, the native setting is `compression.threshold_tokens`. It is
  not set.
- The `auxiliary:` roles use `minimax-m3`, and no other model. `delegation` uses `mimo-v2.5`, the
  cheapest model on the account. Do not put `deepseek-v4-flash` on these small, frequent tasks.
  Its overhead of about 7,900 tokens costs the most there.
- `auxiliary.session_search` does not exist. Upstream deleted that role (PR #27590), and it is not
  an LLM call. `web_extract` is also not an LLM call.
- The automatic paths (default, fallbacks, `auxiliary`, `delegation`) stay on `minimax-m3` and
  `mimo-v2.5` on purpose. The other models exist so that an interactive `@glm` or `@kimi` works.
  Any gateway key can call any declared model. Only the `memini` key is limited (§ Per-key
  limits).
- `fallback_providers` is `mimo-v2.5` only. Do not add `glm-5.2`. It costs ten times as much as
  minimax-m3, and a fallback starts exactly when the account is already under pressure.
- Do not add a `moa` block. MoA is a virtual provider. It runs only when `model.provider` is
  literally `moa`, and ours is `custom:agentgateway`. `moa.default_preset` names the preset that
  the picker uses. It does not turn on MoA.
- `agent.max_turns` is 40. `delegation` is 2 children and depth 1, and the upstream default is 3
  and 1. Both settings limit the worst case of a single run.

### Model selection is measured, not assumed

agentgateway has a real cost catalogue (§ Cost). Within the allowance of the account, the
remaining selection criteria are accuracy and latency.

A bake-off on 2026-08-16 ran each model twice against the actual workload: emit the exact
notification JSON, and make a tool call that must leave out an unused parameter. `minimax-m3`
was correct in 129 completion tokens and 1.9s. `deepseek-v4-flash` was also correct, but it used
7,934 tokens and 36s, so it is the least efficient model despite its name. `qwen3.7-max` and
`kimi-k2.6` each got the JSON wrong once. `qwen3.7-max` miscounted, so it is not suitable for jobs
whose whole output is counts. Before you change an assignment, run the bake-off again. Do not
choose a model by its name.

### kimi-k2.7-code rejects `temperature`

The provider returns 400 on any `temperature` value other than 1. So every agent call failed,
while a bare curl succeeded. agentgateway pins the value. `models/agentgatewaymodel.yaml` is a
standalone model, not a member of the `agentgateway-opencode-go` ResourceSet. The reason is its
`finalTransformations`, which rewrite `temperature` to `1`. If you move the model into the
ResourceSet, you lose that rewrite.

---

## Cost

OpenCode Go is a $10/month subscription with a hard usage limit, not a bill. The account is
metered in dollars of model value. It cuts off when a window is used up:

| Window  | Allowance |
| ------- | --------- |
| 5 hours | $12       |
| 7 days  | $30       |
| Monthly | $60       |

When the allowance is used up, every model returns `429 GoUsageLimitError` at the same time. All
eight models resolve to one `opencode.ai/zen/go` workspace. That is why `fallback_providers`
cannot rescue a quota event (#1813). "You are at $60" means that the allowance is spent. It does
not mean that anyone charged $60.

### Spend figures

Spend figures from before 2026-10-26 (the LiteLLM era) have no meaning, because LiteLLM reported
$0.00 for every opencode-go call (#1832). For that period, use `/opt/data/cron/usage_audit.jsonl`,
the per-fire token ledger.

agentgateway prices calls from the ConfigMap `agentgateway-model-costs`. It holds USD per 1M
tokens for input, output and `cacheRead`. The source is <https://opencode.ai/docs/go/#usage-limits>,
with deepseek at the Peak rate. Without `cacheRead`, the gateway billed cache reads at the full
input rate, and spend read about 3x too high. About 87% of the hermes traffic is cache reads.

Spend is the metric `agentgateway_gen_ai_client_cost_usd_total`, labelled by `user_id`. So the
spend of one key is a query, not a lookup.

### Where the cost comes from

An hourly `cluster-health` run once averaged 774K prompt tokens. That alone was enough to overrun
the $60 month. A run has two cost terms, and the second one is the larger:

- A fixed prefix of about 22,000 tokens. It holds the system prompt, the skill, the native tool
  registry of hermes, the index of bundled skills and the MCP tool schemas. Every call pays it.
- Linear context growth of about 1,800 tokens per turn, from the tool results that pile up. Every
  turn sends the whole context again. So the total cost is roughly `turns × average context`,
  which grows with the square of the turn count.

So the turn count has the strongest effect. The cadence is second, and the fixed prefix is third.

Do not judge from a single run. The historical range per run is 52K to 4.9M. Judge a change over
a week of `usage_audit.jsonl`, never over one sample.

### MCP tool schemas are charged on every turn

hermes once mounted both the `ops` tier and the `general` tier. Their `tools/list` payloads were
several times larger than the payload of the `agent` tier. To measure a tier:

```bash
# from inside the hermes pod, after an initialize that returns a Mcp-Session-Id
curl -s -X POST "http://agentgateway.cortex.svc.cluster.local:4000/agent/mcp" \
  -H "x-api-key: $AGENTGATEWAY_API_KEY" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | wc -c
```

### The `agent` MCP tier

hermes uses its own tier, `mcp-agent`. It carries only what the hermes skills call: `k8s`, `flux`,
`searxng`, `victoria-logs`. Its endpoint is `/agent/mcp`. The MCP server is registered as
`ai-agent`, and the key goes in `x-api-key`. Only the hermes key can use this tier. The tier
rules and the tool count of each server are in `cortex-mcp.md`.

To give hermes a new target, add it to `mcp-agent` in
`kube/clusters/artemis/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml`. Then hermes pays
for the schema of that target on every turn of every run. Before you add one, weigh that cost
against § Cost. `forgejo` and `github` are large, and no hermes skill calls either one. The skills
reach Forgejo over `curl` with `$FORGEJO_PAT`.

### `x-opencode-session` is mandatory and agentgateway injects it

OpenCode Go requires a stable `x-opencode-session` for each conversation. It hard-rejects a request
without one: `400 MissingSessionID — Request is missing x-opencode-session and cannot be routed
efficiently`. The error cannot be retried, so it kills a whole cron fire.

Every model requires the header.

Hermes cannot supply the header, and client-header forwarding cannot supply it either:

- Hermes sends the header only when its provider or base URL matches `opencode-*` or an
  `opencode.ai` host. Ours is `custom:agentgateway`, which points at the in-cluster proxy, so it
  matches neither. The upstream fix (`NousResearch/hermes-agent` PR #101864) does not apply to our
  provider shape.
- Forwarding client headers does not help, because the client never sets this header.

So the gateway injects the header for each model, under `policies.headers.request.set` in
`models/resourceset.yaml` (and in `agentgatewaymodel.yaml` for kimi):

```yaml
- name: User-Agent
  value: artemis-agentgateway/1.0
- name: x-opencode-session
  value: artemis-<model>
```

`User-Agent` is there because Go also asks clients to identify themselves. The gateway does not
forward the `User-Agent` header of the client.

Know the limits of this workaround. The id is stable per model, not per conversation, and Go asks
for one id per conversation. The id passes the check. But it gives the Go router one bucket per
model instead of one bucket per session. When hermes ships PR #101864 in a tagged release and can
send the header for a custom provider, replace this id with a real per-conversation id. Do not
use the trick anywhere else.

Separately, this header was never about caching. Caching already worked without it. The team
measured that 69% of the hermes prompt tokens are cache reads. For `minimax-m3` and `mimo-v2.5`,
90–94% of the input tokens are cache reads. The cache keys are on the server side.

### Per-key limits

Every key has a limit of 2,000,000 tokens per hour (local, per replica). The limit counts every
token sent, cached context included. One rule covers every key, so the limit cannot differ per
key.

For this reason kritika does not use agentgateway. One agentic review sends its context again on
each step, and one review used 6,000,000 tokens in under three minutes. kritika calls OpenCode Go
directly with the same account key.

The old LiteLLM 30-day dollar budgets per key are gone. agentgateway cannot enforce dollar
budgets in Kubernetes mode, only in standalone mode. The team accepted that loss. So a runaway is
limited per hour, not per month. Watch `agentgateway_gen_ai_client_cost_usd_total` by `user_id`
against the $60 limit.

The `memini` key can use only `opencode-go/minimax-m3`, through a per-model Deny in the
ResourceSet. So a memini misconfiguration cannot reach the expensive models.

### If the allowance is tight again

These steps are in order of impact, largest first, per the cost breakdown above:

1. Cut turns. Cost grows with the square of the turn count. Shorten the sweeps of the skill, drop
   optional steps, and lower `agent.max_turns`.
2. Widen the cron interval. It multiplies everything linearly.
3. Trim the `agent` MCP tier. Trimming it only moves the fixed prefix.
4. Lower `model.context_length`, so that a runaway compacts sooner.
5. Move a job to a cheaper model. The prices are in the ConfigMap `agentgateway-model-costs`.

A measured budget check turns the cadence decision into arithmetic, not a guess. At
$0.1175/run, a run every 2 hours is 12 runs/day, about $42/month. A run every 4 hours is 6
runs/day, about $21/month.

`cluster-health` is now script-first. The 30-minute fire is a shell script and uses no tokens.
The agent runs only when the findings are new, or when the same findings are 4 hours old (§ Cron
jobs). A quiet cluster costs nothing. The worst case is a permanent finding that wakes the agent
every 4 hours, which was the old cadence.

The measured run was a catch-up after five failures in a row, and it used 28 of its 40 turns. So
it is an upper bound, not a typical fire. A quiet run once cost as little as 52K tokens. After a
week, measure again from `usage_audit.jsonl`. Do not trust either number.

---

## Cron jobs

Git declares the jobs: `app/cron/jobs.yaml`, ConfigMap `hermes-cron`. A job is in `jobs.json`
(runtime state on the PVC) because the `cron-reconcile` init container put it there at boot.

| Job              | Schedule       | Model                    | Script                    |
| ---------------- | -------------- | ------------------------ | ------------------------- |
| `cluster-health` | `*/30 * * * *` | `opencode-go/minimax-m3` | `cluster-health-check.sh` |

### How a job is declared

Each job has one entry, matched by `name`. Every key except `name` and `schedule` is optional. If
you leave a key out, the reconcile does not manage it and keeps the live value. If you list a key,
every boot forces it to the declared value.

| Key        | Meaning                                                                     |
| ---------- | --------------------------------------------------------------------------- |
| `name`     | the match key                                                               |
| `schedule` | cron expression, `every 2h`, `30m`                                          |
| `skills`   | list of skill names (`[]` clears them)                                      |
| `script`   | file under `/opt/data/scripts/`, relative path                              |
| `model`    | per-job model pin (only the CLI can set it, not the cron tool of the agent) |
| `deliver`  | `local` (save only), or a delivery target                                   |
| `enabled`  | `false` pauses, `true` resumes (default `true`)                             |

`cron-reconcile` is `app/cron/reconcile.py`. It runs with the python in the image, as uid 10000,
and it needs no managed configuration mount. It reads `jobs.json` read-only, and it writes only
through the CLI:

- If the name is missing, it runs `hermes cron create`.
- For each field that differs, it runs `hermes cron edit <id>`.
- For `enabled`, it runs `hermes cron pause|resume`.

A second boot changes nothing and logs `matched <name>: nothing to change`. If `jobs.json` holds
a job that the file does not name, the reconcile leaves it alone and logs
`unmanaged job left untouched`. So a job made in the dashboard survives a reboot, and it is also
not in git.

If one job fails, the reconcile logs `ERROR ...` and continues with the rest. The container still
exits 0. If the YAML does not parse, or the file has no top-level `jobs` list, the container exits
2 and the pod stays in `Init`. This is on purpose.

To add or change a job:

1. Edit `app/cron/jobs.yaml`.
2. If the job needs a new script or skill, also edit `app/scripts/` or `app/skills/`.
3. If you added a script file, register it in the `hermes-scripts` generator of
   `kustomization.yaml`.
4. Land the change like any other manifest change.

Reloader restarts the pod, and the reconcile runs before the app starts. The scheduler reads
`jobs.json` again on every tick, so you do not need to do anything else.

To remove a job, take it out of the file and run `hermes cron remove <id>` in the pod. The
reconcile never deletes a job. If you change a field with `hermes cron edit` or in the dashboard,
and the file lists that field, the next boot reverts the change. To see the result, run
`kubectl -n cortex logs deploy/hermes -c cron-reconcile --context artemis` and
`hermes cron list`.

Scripts are not symlinks. The scheduler refuses a script that resolves outside
`/opt/data/scripts/`. So on every boot, `init` copies each `/run/scripts/*.sh` there with mode
`0755`. An edit in git replaces the copy. A `.sh` file runs under bash, and any other file runs
under python. The shebang is ignored.

### cluster-health: script first, agent on new findings

Every 30 minutes, `cluster-health-check.sh` runs with no LLM. It does what the skill used to do by
hand. It looks for these findings:

- Alertmanager v2 alerts, with Watchdog excluded.
- Nodes that are not Ready, or that are under Memory, Disk or PID pressure.
- Pods that are Pending for over 10 minutes.
- Targets with `up == 0`.
- The static smartctl `pantheon` target, by name.

It uses only `curl`, `sed` and `sha256sum`. It uses no `jq`, no `kubectl` and no python. It calls
only endpoints that the network policy allows: alertmanager 9093, victoria-metrics 8428, chaski 8080.

| Outcome                                                         | What happens                                                                                                                                         |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| No findings                                                     | Prints the summary and ends with `{"wakeAgent": false}`. Posts the chaski `info` itself, at most once per 4h (`last-quiet-notify` in the state dir). |
| Findings, same fingerprint as the last wake, woken under 4h ago | Prints the summary and ends with `{"wakeAgent": false}`.                                                                                             |
| Findings that are new, or the same ones 4h old                  | Stores `<epoch> <fingerprint>` in `last-wake` and prints the summary with no gate line. The agent wakes with the output as its context.              |
| alertmanager or VictoriaMetrics unreachable                     | That is a finding (`check-failed: ...`), so it wakes the agent once per 4h.                                                                          |

The state files are in `/opt/data/workspace/cluster-health/`. The fingerprint is a hash of the
sorted finding keys (alert fingerprint, node, pod, target), not of the text. So the `since`
timestamps do not change it.

A finding that clears does not reset `last-wake`. So a flapping alert is deduplicated for 4h, and
it does not wake the agent on each flap. The other side is that nothing wakes the agent when a
finding clears. So the agent closes an Open case row in `resolved-cases.md` at the next wake, not
when the finding resolves. The script writes the stamp when it decides to wake, not when the run
finishes. So the script does not retry a failed agent run for 4h.

The script gate and the prompt are in `cron/scheduler_prompt.py` and `cron/scheduler.py`:

- The gate is the last non-empty stdout line. If that line is the JSON `{"wakeAgent": false}`,
  the agent does not wake. Anything else wakes it.
- On a wake, stdout (with secrets redacted) goes in as a `## Script Output` block above the
  skill.
- Empty stdout also skips the agent.
- A non-zero exit or a timeout (`HERMES_CRON_SCRIPT_TIMEOUT`) injects a `Script Error` block and
  wakes the agent. So the script always exits 0 once it has decided.

To run the script by hand against nothing live, use
`DRY_RUN=1 STATE_DIR=/tmp/ch bash /opt/data/scripts/cluster-health-check.sh`. `DRY_RUN=1` prints
the chaski payload instead of posting it. The state files still go to `STATE_DIR`, so always point
it at a directory that you can throw away.

### Other cron facts

Use a cron expression, not an `interval:` schedule. Interval schedules re-arm from the
completion of the run, so the run time drifts. A cron expression pins a fixed minute. Alertmanager
already pages in real time, so `cluster-health` is an extra audit, not the alerting path.

The retired jobs `readme-sync` and `forgejo-pr-review` are not in `jobs.yaml`. If either is still
in `jobs.json`, remove it with `hermes cron remove <id>`, because the reconcile never deletes a job.

`cron.catch_up_missed` is `false`. With the default (`true`, checked on v0.22), a slot that was
missed while the pod restarted fires once at start. Reloader restarts the pod on every skill or
configuration change. With a 30-minute script cadence, a skipped slot costs nothing, and the next
slot is at most 30 minutes away. The scheduler logs the skip and re-anchors to the next slot.

`jobs.json` is runtime state on the PVC (`/opt/data/cron/jobs.json`). It is an object,
`{"jobs": [...], "updated_at": ...}`, owned by uid 10000. Do not edit it by hand. Use
`hermes cron create|edit|pause|resume|remove`, which writes it with the correct owner.
`kubectl exec` also enters the container as uid 10000. The dashboard API is behind pocket-id SSO
(`no_cookie`), so you cannot script it with `API_SERVER_KEY` alone.

To list the jobs:

```bash
POD=$(kubectl -n cortex get pod --context artemis -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app --context artemis -- hermes cron list
```

---

## Skills — read-only from git

Git is the only source of the skills that we own:
`ls kube/clusters/artemis/apps/cortex/hermes/app/skills/`. Each skill becomes a generated
ConfigMap `hermes-skill-<name>`. That ConfigMap is mounted read-only as a directory at
`/etc/hermes-skills/<name>` on `app` and `init`. Hermes loads it through `skills.external_dirs` in
`configmap.yaml`. Nothing is copied onto the PVC, so there is no drift and no orphan to clean up.

- There is no `subPath`, because a `subPath` mount never receives ConfigMap updates. A skill with
  subdirectories places its files with `items` in the `persistence` entry
  (`path: references/x.md`). Scripts carry `mode: 0o755`. When a ConfigMap changes, Reloader
  restarts the pod.
- Hermes cannot change the skills. The mount is read-only. External dirs are read-only to
  autonomous curation. `skills.write_approval: true` stages any skill write under
  `/opt/data/pending/skills/` instead of applying it. A skill change is a PR that a human merges.
  See § Changing a skill.
- `skills.disabled` lists every bundled skill except the ones that a cron job names
  (`grep -A3 '"skills"' /opt/data/cron/jobs.json`). Each image bump can add new bundled skills, and
  they arrive enabled. To rebuild the list, run
  `kubectl -n cortex exec deploy/hermes -c app --context artemis -- cat /opt/data/skills/.bundled_manifest`
  and take the first field before `:` on each line.

The bundled skills still live in `/opt/data/skills/<category>/<name>/SKILL.md`, next to
`.usage.json`. That file holds `use_count`, `last_used_at` and `patch_count` for each skill. The
startup log line `Syncing bundled skills into ~/.hermes/skills/` is wrong. The sync goes into
`~/skills/`.

### The anti-collision guard

hermes can find the same skill name in `/opt/data/skills` and in an external dir. It picks one by
precedence (checked on v0.22). The local copy wins, and the git copy is hidden, with one warning in
the log (`agent/skill_utils.py`). Older releases failed loudly with `Ambiguous skill name`. Now a
stale local copy runs silently in place of the git skill.

So on every boot, `init` reads the `name:` of each mounted skill. It then deletes any directory
under `/opt/data/skills` whose `SKILL.md` has the same name. Before it deletes the directory, it
copies any `references/*-triage.md` to `/opt/data/workspace/cluster-health/archive/<file>.full.md`
with `cp -n`. So the old history survives the first boot after the migration.

Discovery matches the literal filename `SKILL.md` anywhere under a skills root, dot-directories
included (`iter_skill_index_files` in `agent/skill_utils.py`). Never write a file named `SKILL.md`
outside a real skill. A copy parked under a dot-directory once registered a second skill with the
same name. It stopped the cluster-health audit for about 27 hours. Discovery also walks the
`..data` and timestamped directories of a ConfigMap mount. They resolve to the same file, and
discovery removes the duplicates.

### cluster-health state

The skill appends to logs, so its state cannot live in the read-only skill directory. Everything
it writes is under `/opt/data/workspace/cluster-health/` on the PVC: `resolved-cases.md` (the case
index), and one `*-triage.md` recurrence log for each alert family. Git ships only static material
in the skill (`references/node-baselines.md`, `scripts/`).

The starting content of the state files is in `app/seed/cluster-health/`, ConfigMap
`hermes-cluster-health-seed`. It is mounted into `init` only. `init` copies each file with
`cp -n`, so it never overwrites live state. So an edit to a seed file in git does not reach a
running pod. To seed one file again, delete the live file and restart the pod.

### Changing a skill

A human edits the files under `app/skills/` and lands the change like any other manifest change
(`AGENTS.md` rule 1). For hermes, the `skill-change-pr` skill opens a PR as dusk-bot through the
Forgejo contents API. It never merges the PR, because the merge deny glob in § Autonomy posture
blocks that.

### Scanner-safety is load-bearing for unattended runs

The security scanner of the agent flags two patterns as HIGH: a pipe to an interpreter
(`curl … | python3`) and an inline interpreter script (`python3 -c`). It then marks the command
`pending_approval`, which stalls a cron run. The command shapes that the skills must use are in
`skills/cluster-health/SKILL.md` § Rules for every command. The Forgejo `contents` PUT recipe is in
`skills/skill-change-pr/SKILL.md`. The skills keep their own copies, because hermes loads each
skill on its own.

---

## Autonomy posture — what hermes is allowed to do unattended

hermes once patched its own skills, and none of the patches reached git. Skills are now read-only
(§ Skills), so it cannot do that again.

### 1. Cron approvals (`approvals` in `configmap.yaml`)

`cron_mode: deny` blocked every `terminal` call that the smart guardian flagged. The skills do all
their Forgejo and chaski work through `curl`. So that setting stopped both the self-improvement PR
flow and the notification POST. The agent was silently unable to report. It was also silently
unable to report that failure. `execute_code` uses the same setting (`tools/approval.py`), so
there was no workaround inside the pod.

Now the setting is `cron_mode: approve`. These layers enforce the rules. The deny globs act before
any bypass (`_match_user_deny_rule` in `tools/approval.py`):

| Layer                           | Scope                    | Enforces in cron?                                                                                                                      |
| ------------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| code-shipped hardline blocklist | `rm -rf /`, poweroff, …  | yes, always                                                                                                                            |
| `approvals.deny` fnmatch globs  | the `terminal` tool only | yes. This is the real control.                                                                                                         |
| `approvals.smart_policy`        | guardian system prompt   | no. ESCALATE resolves to approve under `cron_mode: approve`. It still binds interactive and gateway sessions, and it documents intent. |
| `mcp-k8s` ClusterRole           | the MCP k8s tools        | yes. This is RBAC, not approvals.                                                                                                      |

The important split is this: deny globs limit the shell, and the k8s server limits the cluster
tools. A glob like `*kubectl*delete*` cannot restrict an MCP tool. The k8s server sets
`disable_destructive = true` (`mcp/app/k8s/resources/config.toml`), so it hides every tool that
changes a resource, and Hermes has no delete or scale tool at all. The ClusterRole still grants
pod and job delete, but no tool uses those grants. The cluster-health skill is notify-only for this
reason. Give a new deny glob a leading `*` and a trailing `*`.
Matching ignores case and runs over deobfuscated variants of the command, so quoting tricks do
not get around it.

To read the live deny globs, run
`grep -A16 '    deny:' kube/clusters/artemis/apps/cortex/hermes/app/configmap.yaml`.

### 2. RBAC — the pod holds none; the MCP path is the only one

hermes reaches the cluster in one way only: the k8s MCP tools, under `mcp-k8s-sa`, through the
`agent` tier of agentgateway. The pod itself has no cluster access:

- It mounts no ServiceAccount token. The app-template default for `automountServiceAccountToken`
  is `false`, and nothing overrides it. The image has no `kubectl`.
- The `hermes` ServiceAccount exists but is bound to nothing. Do not bind a role to it.
- No skill or configuration calls the kube API from inside the pod.
  `grep -rniE 'kubectl|serviceaccount|KUBERNETES_SERVICE' kube/clusters/artemis/apps/cortex/hermes/app/skills`
  finds only prose that says not to.

To make sure, run
`kubectl auth can-i --list --as=system:serviceaccount:cortex:hermes -n cortex --context artemis`.
It shows only the self-review and discovery rules that every account has.

`mcp-k8s-sa` (the MCP server) has broader access, and it is cluster-wide. Everything is read-only
(`get/list/watch`), except these grants:

- `deployments/scale`, `statefulsets/scale`, `replicasets/scale`: `get, patch, update`
- `pods`: `delete`
- `jobs`: `delete`
- `pods/exec`: `create`
- `events`: `create`

`helmreleases` and `kustomizations` are read-only, so the MCP path cannot start a Flux reconcile.
Workloads are read-only too, and scale is the only write (see `cortex-mcp.md`). The MCP path
cannot create or delete workloads. It cannot touch Talos or node-level state.

> `mcp-k8s` holds no `secrets` rule (see `cortex-mcp.md`). The ClusterRole carries only the
> External Secrets CRs (`externalsecrets`, `secretstores`, `clustersecretstores`). These are
> references, not secret data. To make sure, run
> `kubectl get clusterrole mcp-k8s --context artemis -o jsonpath='{range .rules[*]}{.resources}{" -> "}{.verbs}{"\n"}{end}'`
>
> `mcp-k8s-sa` is the only path to the cluster, and it cannot read Secret data. The deny globs and
> the smart-policy ESCALATE rule limit the shell only. Approvals control the `terminal` tool, and
> RBAC controls the k8s tools. So RBAC is the real control. The `mcp-k8s` ClusterRole is
> `kube/clusters/artemis/apps/cortex/mcp/app/k8s/rbac.yaml`.

---

## Operational gotchas

Probes: all three probes prove that cron is alive, not only that the process answers. Startup and
liveness use an exec probe that needs two things:

- The unauthenticated `/health` of the gateway on 8642 answers (`curl -fsS -m 4`).
- `/opt/data/cron/ticker_heartbeat` is under 300 seconds old.

That file holds `<epoch> <pid>`. The cron ticker rewrites it about every minute
(`record_ticker_heartbeat` in `cron/jobs.py`). So a gateway that serves HTTP while its scheduler
thread is dead fails the probe. The `/api/health` of the dashboard on 9119 is also
unauthenticated, and it also works as a target. But the probes always hit 8642.

Readiness stays a plain `httpGet` on `/health`. A restart fixes a stale ticker. Removing the pod
from the Service only takes the dashboard down with it.

Startup allows `60 × 10s = 10 minutes` for the first heartbeat before liveness can act. Liveness
then fails after `3 × 30s`, with a 10s probe timeout. Boot takes about a minute (three init
containers plus the injected `k8tz`, no download, no source copy), so that budget has room to spare.
Before you make it tighter, measure the init duration on a cold PVC. The ticker is async
(`cron_tick(sync=False)`), so a long agent run does not delay the heartbeat.

To make sure that the probes pass, run these commands. The first shows no `Unhealthy` events:

```bash
kubectl -n cortex describe pod -l app.kubernetes.io/name=hermes --context artemis
kubectl -n cortex exec deploy/hermes -c app --context artemis -- cat /opt/data/cron/ticker_heartbeat
```

HelmRelease timeout: `spec.timeout` is `15m`, with remediation retries for install and upgrade. The
Helm default of 5m is too small for `strategy: Recreate`, `terminationGracePeriodSeconds: 120` and
the init containers. With 5m, an upgrade timed out mid-audit, and Flux rolled back.

`HERMES_CRON_TIMEOUT` is an inactivity timeout, not a wall-clock limit. Per
`/opt/hermes/cron/jobs.py`, a job that keeps producing output can legitimately run past it, and
`0` turns it off entirely. With `0`, only the 1800s stale-claim TTL recovers a tick that actually
died. So a run that hangs but stays alive can block without limit. It is `900`.
`streaming.enabled` is `false`, so a single slow LLM call is silent for its full duration. Do not
lower this value to detect a slow model.

`wait: false` on the Kustomization: `ks.yaml` sets `wait: false` with no `healthChecks`. So the
Kustomization reports `Applied revision` even while the HelmRelease under it fails or rolls back.
Judge a hermes deploy by `flux get helmrelease hermes -n cortex --context artemis`. Never judge it
by the Kustomization alone.

`render-ks` cannot validate chart output. It renders the resources of the Flux Kustomization (the
HelmRelease, the ConfigMaps), not the templated chart. So probe or container changes seem to "not
render". To validate those changes, run `helm template` against the app-template chart and the
`spec.values` of the HelmRelease.

Backups, and how an `exec` silently breaks them: the kopiur `SnapshotPolicy` takes an hourly
snapshot of `/opt/data` to `atlas`
(`kubectl get snapshotpolicy -n cortex hermes --context artemis`). `LAST-VERIFIED` is empty, so
nobody has tested a restore of the snapshots. Use the `restore-drill` skill.

A `kubectl exec` into `app` runs as uid 10000, the container user. So `sh -c`, `cp` and `tee`
write files that the scheduler and the kopia mover can read. The mover is also uid 10000. A
root-owned file from an exec once made every hourly snapshot fail for seven hours, because kopia
fails the whole snapshot on one unreadable file. To make sure that no file has another owner, and
to force a snapshot:

```bash
kubectl -n cortex exec deploy/hermes -c app --context artemis -- find /opt/data ! -user 10000   # expect only lost+found
mise run //kube/clusters/artemis:snapshot-pvc cortex hermes
```

### Run as uid 10000

The pod runs as `10000:10000` with `fsGroup: 10000` and `runAsNonRoot: true`. All capabilities
are dropped, privilege escalation is off, and the root filesystem is read-only. When the image
starts non-root, it accepts only uid 10000. `docker/stage2-hook.sh` and `docker/main-wrapper.sh`
refuse any other non-root uid. The `hermes` user of the image has that uid. The writable paths are
`/opt/data` (the PVC), `/run` (s6, an emptyDir) and `/tmp` (an emptyDir). Nothing else is written.

- `S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES=1` is required. Without it, s6-overlay
  refuses an emptyDir `/run` (mode 0777). `HERMES_UID`/`HERMES_GID` and every added capability are
  gone. The app container no longer has a `usermod`, a remap or a root `chown`.
- The stage2 hook still calls the configuration migrator and the dependency refresh through
  `s6-setuidgid`, which needs `CAP_SETGID`. Both fail as non-root with
  `Warning: ... failed; continuing` in the boot log. That is expected.
- The migrator does nothing anyway while `_config_version` in the `user.yaml` key of
  `configmap.yaml` equals the version of the image. That version is `53` since v0.23.0. When the
  migrator runs as uid 10000, it exits 0 and leaves the file unchanged. If an image bump raises the
  version, raise the number in `user.yaml` with it, or add a `config-migrate` init as bjw-s does.
- The dependency refresh matters only for opt-in plugin dependencies after an image upgrade.
- The `init` and `install-memini` containers also run as 10000 with a read-only root filesystem.
- No container runs as root. Every file on the PVC is `10000:10000`. If someone restores an old
  1000-owned snapshot outside Kopiur, a root step is necessary to change the owner. A non-root
  process cannot chown files that it does not own, and `fsGroup` does not change the owner.
- Kopiur: `KOPIUR_PUID`/`KOPIUR_PGID` are `10000` in `ks.yaml`, for the `SnapshotPolicy` mover
  and the `Restore` mover (`kopiur.md` § kopiur, the "Mover uid" bullet). A restore writes files as the mover uid. So
  a restore of an older snapshot (owned by 1000) with these settings gives files owned by uid
  10000, which is what the pod needs. To change the `Restore` spec, delete the `Restore` CR once,
  so that Flux recreates it (`kopiur.md`).

### Network policy

`networkpolicy.yaml` selects the hermes pod for ingress and egress. It drops all traffic that it
does not list.

Ingress comes only from the `edge-gateway` envoy pods, on 9119 and 9120. Kubelet probes on 8642
come from the node host, and Cilium always lets that traffic through. Nothing else calls 9119,
9120, or the API server of hermes on 8642.

| Egress                         | Port  | Why                                                                       |
| ------------------------------ | ----- | ------------------------------------------------------------------------- |
| kube-dns                       | 53    | all name resolution                                                       |
| `agentgateway`                 | 4000  | every model call, and the `agent` MCP tier (k8s, flux, searxng, victoria) |
| `memini`                       | 8080  | memory plugin                                                             |
| `searxng`                      | 8080  | `web.search_backend`                                                      |
| `chaski` (observability)       | 8080  | skills POST their notification summaries                                  |
| `alertmanager` (observability) | 9093  | cluster-health pulls firing alerts                                        |
| `victoria-metrics` (observ.)   | 8428  | cluster-health and `targetdown-check.sh` PromQL                           |
| `vmagent` (observability)      | 8429  | `targetdown-check.sh` scrape-target health                                |
| `edge-gateway` envoy pods      | 10443 | `git.dcunha.io` (PRs as dusk-bot) and `id.dcunha.io` (dashboard OIDC)     |

`git.dcunha.io` and `id.dcunha.io` resolve to the edge-gateway LoadBalancer (`10.10.99.90`).
Cilium translates that address to the envoy pods before it applies policy. So the rule names the
pods and their container port (10443), not the address. The cost is that the rule allows every
route on `edge-gateway`, not only those two hosts. SNI filtering needs a `CiliumNetworkPolicy`.

There is no internet egress. Three things try the internet, and they work in a reduced way
without it:

- The models.dev catalogue refresh. Hermes serves the catalogue from
  `/opt/data/models_dev_cache.json`, and every model has an explicit `context_length`.
- Plugin update checks.
- `hermes plugins install`.

The last one is a real limit. If you bump the memini SHA in `install-memini`, the container
clones from github.com and installs dependencies from PyPI. While the policy blocks that traffic,
the init container fails and the pod stays in `Init`. The `hermes` Kustomization reconciles every
15m. If it is not suspended, it removes the temporary rule while the install runs. To bump the SHA:

1. Suspend the root: `mise run //kube/clusters/artemis:suspend-ks flux-system flux-system`.
2. Suspend the target: `mise run //kube/clusters/artemis:suspend-ks cortex hermes`.
3. Add a temporary egress rule for `0.0.0.0/0` on 443. Apply it with
   `mise run //kube/clusters/artemis:apply-ks cortex hermes`.
4. Bump the SHA, and apply again. Wait until the init container finishes.
5. Remove the temporary rule, and apply again.
6. Commit, then resume the root first and the target second. `commit-style.md` § The sequence has
   the full order, and it wins over this list.

---

## Notification format

Every skill notification goes through chaski, and chaski owns the layout. The skill supplies the
data, and chaski supplies the format. Skills POST `{skill, status, summary, stats{}, items[], url}`
and nothing else. For the template mechanics, the dispatch order that makes the hermes branch
work, and how to validate a template change offline, see `.agents/references/observability.md`
§ chaski Notification Templates.

## Debugging runbook

```bash
flux get helmrelease hermes -n cortex --context artemis                       # the real deploy verdict
kubectl -n cortex logs deploy/hermes -c app --context artemis --tail=200
kubectl -n cortex logs deploy/hermes -c init --context artemis --previous     # stale-skill guard and seeding
kubectl -n cortex logs deploy/hermes -c cron-reconcile --context artemis --previous   # job matched, edited or errored
POD=$(kubectl -n cortex get pod --context artemis -l app.kubernetes.io/name=hermes \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n cortex exec "$POD" -c app --context artemis -- cat /opt/data/cron/jobs.json
kubectl -n cortex exec "$POD" -c app --context artemis -- ls /etc/hermes-skills /opt/data/workspace/cluster-health
```

When cron stops firing, the cause is almost always one of four things. Here they are in order of
likelihood, most likely first:

1. A stale local copy hides a skill. The run succeeds with the wrong skill.
2. An approval denial.
3. `HERMES_CRON_TIMEOUT` was reached.
4. The gateway hung while the probes passed.

First search the gateway log for `is shadowed by a higher-precedence copy`. It costs one command.

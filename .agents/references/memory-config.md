# Memory & MCP Configuration

This file describes how AI agents get tools and long-term memory in this repo. Update it when the
MCP layout or the memory system changes.

---

## Five registration files — keep them in sync

There are five registration files. Only two of them are in this repo. When you add or retire a
tier, edit every row:

| File                                                 | Client                           | Auth mechanism                                                                                                  | In this repo?                                     |
| ---------------------------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `.mcp.json`                                          | Claude Code, this repo           | `headersHelper … <tier>` returns `{"x-api-key": …}` at call time                                                | yes                                               |
| `opencode.json`                                      | opencode, this repo              | MCP tiers: `x-api-key: {env:MCP_<TIER>_KEY}`. memini: `Authorization: Bearer {env:MEMINI_API_KEY}`. From `.env` | yes                                               |
| `~/.claude/local-marketplace/dcunha-tools/.mcp.json` | Claude Code, every other project | same helper, same per-tier argv                                                                                 | no, not dotfiles-managed either                   |
| User scope in `~/.claude.json`                       | Claude Code, any directory       | same helper. Added with `claude mcp add-json -s user …`                                                         | no, machine-local state, no automation reaches it |
| Windows Zed `%APPDATA%/Zed/settings.json`            | Zed                              | keys inlined in plaintext                                                                                       | no, Windows filesystem, no automation reaches it  |

The server names are `ai-ops` and `ai-general` in every file. Claude Code shows their tools as
`mcp__ai-<tier>__<target>_<tool>`.

The tier argument is required. `~/.claude/scripts/ai-headers.mjs` (dotfiles) requires `ops` or
`general` as argv. It reads `op://artemis/agentgateway/KEY_<TIER>` and returns
`{"x-api-key": …}`. There is no fallback key. If you omit the tier, the script fails. It does not
authenticate as something broader. When you add a registration, pass the tier.

opencode reads its keys from the gitignored `.env` file. To make it again, run
`mise run //ai:env`. The task pulls the keys from 1Password. `ai/mise.toml` lists the keys that
it writes. `AGENTGATEWAY_API_KEY` is the model key.
`scripts/eval-instructions.py` uses it against `https://ai.dcunha.io/v1`. Claude Code never reads
`.env`. Its helper script gets the key itself. If a tier works in one client and returns 401 in
the other, `.env` is almost always out of date.

`memini` is registered directly in `opencode.json`. Claude Code gets it from the memini plugin
instead, so it is not in `.mcp.json`. This difference is intentional.

---

## `.mcp.json` — Claude Code MCP Servers

This file is at the repo root. It registers the MCP servers of this project for Claude Code
sessions. Claude Code loads it together with the servers at user scope in `~/.claude.json` and
the servers from Claude Code plugins.

```json
{
    "mcpServers": {
        "ai-general": {
            "type": "http",
            "url": "https://ai.dcunha.io/general/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/ai-headers.mjs general"
        },
        "ai-ops": { "...": "same shape, /ops/mcp, helper arg `ops`" }
    }
}
```

The URL of a tier is `https://ai.dcunha.io/<tier>/mcp`, where `<tier>` is `general` or `ops`.
This file does not list which target is in which tier. To read it, run this command:

```bash
grep -n -B1 'name:' kube/clusters/artemis/apps/cortex/agentgateway/mcp/agentgatewaybackend.yaml
```

The media tools (arr, seerr) are in `ai-general`. There is no separate media tier.

These two are the Claude Code tiers. A third tier, `ai-agent` (`/agent/mcp`, with flux, k8s,
searxng and victoria-logs), is for hermes only. It is not in any registration file, on purpose.
It limits the token budget of hermes. It does not give a different set of capabilities. Do not
add it to a registration file. See `.agents/references/cortex-mcp.md`.

Each tier authenticates with its own API key (1Password item `agentgateway`, fields `KEY_OPS`
and `KEY_GENERAL`). A leaked key or a runaway client affects only one tier. The gateway rejects a
key on the path of the wrong tier. `ai-ops` has privileged access to the cluster. Use it in agent
clients only. Never expose it to a general-purpose chat frontend. `cortex-mcp.md` has the auth
rules. It also says why the key must be an `x-api-key` header and never `Authorization`.

`context7` is the only remote server (`https://mcp.context7.com/mcp`). The other servers run as
Deployments in `cortex` (`cortex-mcp.md` § Layout). The exception is sparkyfitness. Its target
is the server of the app itself, in `default`.

A healthy pod proves that the workload started. It does not prove that the gateway can speak MCP
to it. The gateway skips a target that is down and gives no message (`failureMode: FailOpen`).
The tier then lists fewer tools. To see what a tier exposes, list the tools in a client. To
examine the proxy side, run this command:

```bash
kubectl logs -n cortex -l app.kubernetes.io/name=agentgateway --tail=200 --context artemis
```

The gateway configuration is in `kube/clusters/artemis/apps/cortex/agentgateway/`. The MCP
servers are in `kube/clusters/artemis/apps/cortex/mcp/app/<name>/`.

Update this section when someone adds an MCP server, a tier changes, or a URL moves.

---

## memini — Cross-Session Memory

`memini` gives semantic long-term memory for this project. Claude Code gets it as a plugin, so it
is not in `.mcp.json`. The client adds a prefix to the tool names, so never hardcode a full name.
List the tools and match on the `memory_*` part. opencode gets it as a remote MCP server in
`opencode.json`. That file pins the namespace with an explicit `X-Memini-Namespace` header.

An explicit `X-Memini-Namespace` header wins over the server-side pin. Neither client reports an
error. So a header that is out of date silently splits reads and writes across two namespaces.
`opencode.json` pins `homelab/home-infra`. The Windows Zed configuration still has the flat
`Artemis-Cluster`, so it writes to a place that nothing reads.

- Load: when you start work on a topic that can have prior history, call `memory_recall`,
  `memory_answer` or `memory_briefing`. Read the `scope_header` of the briefing. If it says
  `default`, the namespace did not resolve, and everything you recall belongs to the wrong
  project.
- Save: after a non-obvious discovery, call `memory_remember`. Examples are a quirk, a failure
  mode, or a workaround that takes real effort to work out again.
- What goes to memini and what goes to `.agents/`: `session.md` (always loaded) wins.

The `memini` app (embeddings and storage) runs in the cluster at
`kube/clusters/artemis/apps/cortex/memini/`. The plugin talks to this service. The app is
separate from the plugin and client side above. It embeds with `qwen3-embedding` and reranks with
`jina-reranker`. Both are `llmkube` models in `cortex`. `MEMINI_BACKEND` is `postgres` (shared
CNPG).

Update this doc when the scoping model of the memini plugin changes, or when the in-cluster
deployment moves to another namespace.

---

## Recall & Write-Path Tuning

The manifest has no comments (see `yaml-conventions.md` § No Comments in Manifests), so the
reason for each value is here. The primary source is `docs/guides/tuning-recall.md` in the memini
marketplace checkout.

Find the cause before you tune. Always run `memini doctor` first. A namespace mismatch is the
most common cause of "memini forgot everything". In a mismatch, writes go to one namespace and
recall reads another. No ranking setting can correct a pointer problem. The read set for
`homelab/home-infra` is the repo, its `homelab` ancestor, `personal/exikle` (home), and two links
(`containers`, `fingerjoin`).

| Setting                         | Value    | Why                                                                                                                                                                                                                                                                                                 |
| ------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_WRITE_EMBED_TIMEOUT`    | `20s`    | The unset default is 5s. The pod logged many `embed_timeout` write failures. Each one stored a memory with no vector, so semantic recall can never find it. Recall had 20s. The write path did not.                                                                                                 |
| `MEMINI_RERANK_MAX_DOC_CHARS`   | `1800`   | A rerank pair must fit one physical batch of llama.cpp in `jina-reranker`. The batch started at `uBatchSize: 1024`. At 4000 chars, pairs measured 1042–1244 tokens and the backend returned HTTP 500. memini hides that error and falls back to composite order. It is 2048 now (#2755, see below). |
| `MEMINI_RERANK_POOL`            | `25`     | The default `0` reranks only the results that already go to the caller. So the cross-encoder can never rescue a memory that fused retrieval put below the cut. That rescue is most of its purpose. The value started at 25, not at the ceiling of about 50, because the reranker uses CPU only.     |
| `MEMINI_RERANK_MAX_BATCH_CHARS` | `120000` | The `6000` default splits a deep pool into many serial requests. Many serial requests go past the rerank timeout much more easily than one large body. The setting guards the HTTP payload, not the context. Each pair gets its own forward pass.                                                   |
| `MEMINI_RERANK_TIMEOUT`         | `20s`    | This gives room for the deeper pool. It must stay below the client ceiling (`request_timeout_ms`, 30000 at the last check). If not, a slow rerank makes the client hang up first, and recall returns nothing instead of falling back to composite order.                                            |
| `MEMINI_DEMOTE_AFTER`           | `0`      | This turns off demotion. Demotion exposed many low-confidence durable memories. The "never recalled" clause of the sweeper is almost always true here, because recall runs rarely against a large store.                                                                                            |

### LLM budget — the model, the token cap, and the assessment sweep

These values came after the shared opencode.ai `zen/go` monthly quota ran out. memini was the
biggest LLM consumer in the cluster, and it used the least efficient model available.

| Setting                     | Value                    | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| --------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMINI_LLM_MODEL`          | `opencode-go/minimax-m3` | It was `opencode-go/deepseek-v4-flash`. The 2026-08-16 bake-off in `hermes.md` measured deepseek at 7,934 completion tokens / 35.9s on a task. minimax-m3 answered the same task correctly in 129 tokens / 1.9s. That is about 60x the cost for no gain in accuracy. The team applied that result to hermes and missed it here.                                                                                                                                                                                         |
| `MEMINI_LLM_MAX_TOKENS`     | `8192`                   | This value came with the model change, not after it. The value `0` keeps the built-in 4096 budget of the client, and hidden reasoning tokens use that budget. minimax-m3 is `supportsReasoning: true`. So a used-up budget returns `finish_reason: length`, and the whole pipeline call is silently lost.                                                                                                                                                                                                               |
| `MEMINI_ASSESS_INTERVAL`    | `6h`                     | The default is `1h`. The importance-backfill sweep causes most of the calls. Each hourly run assesses `ASSESS_MAX_PER_RUN` rows in batches of `ASSESS_BATCH`. That is up to ten LLM calls an hour, in addition to dedup. The sweep drains a backlog. So a longer interval makes the drain slower, but it removes no capability.                                                                                                                                                                                         |
| `MEMINI_ASSESS_MAX_PER_RUN` | `100`                    | The default is `200`. This halves the ceiling per run, for the same reason.                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `MEMINI_ASSESS_BATCH`       | `10`                     | The default is `20`. Set on 2026-09-06. `minimax-m3` returns a well-formed `{"scores":[…]}` array that is one or two entries short of a 20-item batch. memini treats a positional length mismatch as a lost batch. A failure in the first batch stops the whole pass, so at batch 20 the sweep wrote nothing. This is not truncation. `finish_reason: stop` came at about 100 completion tokens against an 8192 cap, so a higher `MEMINI_LLM_MAX_TOKENS` does nothing here. At batch 10, the same 100 rows assessed 90. |
| `MEMINI_CHUNK_EMBED`        | `true`                   | This only adds to recall. memini also embeds long memories in overlapping segments. So recall can find a match after `EMBED_MAX_ITEM_CHARS`, not only in the prefix. It runs on the local `qwen3-embedding`, so it uses no upstream quota. The `BACKFILL_INTERVAL` loop builds the segments, not the write path.                                                                                                                                                                                                        |

The cap is a ceiling, not a reservation. A higher `MEMINI_LLM_MAX_TOKENS` does not increase the
spend on calls that give a short answer. It only stops a long answer from being cut off into a
lost call. Truncation is the more expensive failure. The tokens are spent in both cases, and
truncation discards the result.

Do not "fix" a quota outage with a model that has a smaller-sounding name. One opencode.ai
workspace serves all the agentgateway models on one monthly quota. So there is no cheaper tier to
drop to, and no fallback in another provider. `minimax-m3` is already the low-cost option here.
`deepseek-v4-flash` is the expensive one, with a name that sounds fast. See
`.agents/references/hermes.md` § Model selection is measured, not assumed.

### Known-remaining items

- `memini reembed` rewrites the whole store when you change the embedding model. It does not fill
  gaps. Run it only after a change of the embedding model.
- `MEMINI_RERANK_MIN_SCORE` is still `0` (off). It is the only setting that can cut the tail of
  confident noise. A nonsense probe query returned 13 hits over 0.93. The correct value is
  specific to the model, and you must sweep for it. Never copy it from a doc. The 500s are gone.
  But the sweep means little while a deep pool is still near the rerank timeout (see the
  `MAX_DOC_CHARS` item below). You cannot sweep it per request, and recall responses never
  return the rerank score. So sweep offline. Score (query, candidate) pairs against `/v1/rerank`
  directly, or use `go run ./cmd/bench -rerank-gate` from the memini repo.
  [#2753](https://git.dcunha.io/Exikle/home-infra/issues/2753)
- `MEMINI_ASSESSED_SALIENCE_WEIGHT` is still `0`. The assessment sweep runs and costs money. But
  at weight 0, its score goes only to the rerank-pool reservation (`RECALL_IMPORTANCE_RESERVE`).
  The score decides which candidates the reranker sees. It never decides their order. To use
  what the sweep produces, raise the weight. But the weight also controls the lifecycle, not only
  the ranking. Salience controls short-term cap eviction, briefing order, and which memory
  survives dedup. The docs say to benchmark it first, so the team did not change it.
  [#2754](https://git.dcunha.io/Exikle/home-infra/issues/2754)
- `MAX_DOC_CHARS` stays at 1800 because the CPU of the reranker is the limit, not batch size. On
  ymir, a 25-doc pool took 54s at 4000 chars, against a 20s `MEMINI_RERANK_TIMEOUT`. Do not raise
  `MAX_DOC_CHARS` or `RERANK_POOL` until the reranker has free CPU. Before that, time a pool by
  hand: POST 25 docs to `/v1/rerank` through a port-forward.

### The client side is the bigger lever on "memory feels unused"

During the memini tuning, recall events were much rarer than `remember` events, and there were no
`answer` events. Saving is not the problem. Agents almost never call recall. The settings that
matter are client behaviour defaults. The server serves them from `PUT /v1/settings/defaults`.
They are not HelmRelease env values: `recall_limit`, `inject_recall_min_score`,
`inject_pretool_min_score`, `inject_briefing_facts`. To read the live values, use
`GET /v1/settings/defaults`. It is safe and writes nothing. At tuning time, a 0.5 floor cut close
to the median composite score. Raise one setting at a time and watch the `inject` activity
events. If you change all four together, you flood the context and get the opposite complaint.

A client env var wins over the served default. The plugin resolves each setting in this order:
env, then server, then built-in (`effectiveSetting()` in the generated client script of the
plugin). The hooks read the server side from the `POST /v1/handshake` response, not from
`/v1/settings/defaults`. `~/.claude/settings.json` sets `MEMINI_INJECT_RECALL_MIN_SCORE` and
`MEMINI_INJECT_PRETOOL_MIN_SCORE` to `0.6`. So Claude Code on this machine injects at 0.6. The
served `0.5` applies only to clients without the env var. The team keeps the 0.6 on purpose
([#2758](https://git.dcunha.io/Exikle/home-infra/issues/2758)). Change it in `settings.json`, not
through `PUT /v1/settings/defaults`. A change through the API does not reach this machine.
`request_timeout_ms` (served `30000` at the last check) is the ceiling. `MEMINI_RERANK_TIMEOUT`
must stay below it.

---

## Namespace Topology

Namespaces are hierarchical. The layout is:

```text
homelab/                    shared across the infrastructure repos
├── homelab/home-infra      this repo, both clusters (Frostlink moved in on 2026-11-16)
├── homelab/hermes          the hermes agent (set by MEMINI_NAMESPACE, not a pin)
└── homelab/<repo>          any other repo that runs servers or the network, pinned by hand
personal/exikle             follows the user everywhere (MEMINI_HOME)
personal/<repo>             every other repo — the default for an unpinned repo
```

Resolution uses a server-side pin (`GET`/`PUT /v1/pins`). So the pin is the same on every
machine, and every client (hooks, MCP tools, CLI) agrees.

Each repo has two pin keys, not one. A remote pin alone does not cover a checkout with no remote,
or a probe that sees only a path:

| Key                                           | → namespace          |
| --------------------------------------------- | -------------------- |
| `remote:git.dcunha.io/exikle/home-infra`      | `homelab/home-infra` |
| `path:/home/exikle/Artemis-Cluster`           | `homelab/home-infra` |
| `remote:git.dcunha.io/exikle/artemis-cluster` | `homelab/home-infra` |
| `remote:git.dcunha.io/exikle/frostlink`       | `homelab/home-infra` |
| `path:/home/exikle/frostlink`                 | `homelab/home-infra` |

On 2026-11-14 the repo was renamed from `Artemis-Cluster` to `home-infra`. Its memories moved
from `homelab/Artemis-Cluster` to `homelab/home-infra`. The old remote key stays, so a checkout
with the old remote still resolves. On 2026-11-15 the checkout folder moved to `~/home-infra`.
There is no `path:` key for the new folder, because the remote key covers it. The `path:` keys
are for old checkout folders. Remote keys are lowercase. memini matches them
against a normalized remote.

`dotfiles/home/claude/settings.json` (symlinked to `~/.claude/settings.json`) sets no
`MEMINI_NAMESPACE`. It sets `MEMINI_NAMESPACE_PREFIX` to `personal`, `MEMINI_HOME` to
`personal/exikle` and `MEMINI_BASE_URL` to `https://memini.dcunha.io`.

After you change a pin, reconnect the memini MCP server (`/mcp`, then reconnect).
`/reload-plugins` does not reconnect it. The MCP `headersHelper` runs only when the server
connects. Until it reconnects, the hooks and the MCP tools point at different namespaces. Memory
then works only in part, and nothing reports an error.

### How the cascade actually flows

| Direction             | What crosses                                              |
| --------------------- | --------------------------------------------------------- |
| child → parent (up)   | durable tiers, read-only, always on under `scope: "full"` |
| parent → child (down) | only via a per-call `scope: "everywhere"`                 |
| sibling → sibling     | nothing, which is why the explicit link still exists      |
| any write             | stays put unless `visibility:` names an ancestor          |

`homelab/home-infra` keeps explicit links to sibling repos. The shared parent does not replace
any of them, because siblings inherit nothing from each other. To list the links, use
`GET /v1/links` (`X-Memini-Namespace: homelab/home-infra`). A namespace move repoints a link to
that namespace. A re-pin does not. So after you move a repo to a new namespace, make its link
again.

Until 2026-11-16, Frostlink had its own namespace and a tier-restricted link. Its 120 memories
(119 plus 1 superseded) moved into `homelab/home-infra` with `POST /v1/namespaces/move`. That
call merges into an existing namespace and keeps the ids. The move repointed the two frostlink
pins. It also left a link from `homelab/home-infra` to itself, and the team deleted that link.
The memories of both clusters now share one namespace, so their episodic memories show up
together. If a memory is true of one cluster only, name the cluster in its text.

### Write routing — the rule

The default project visibility is correct for almost everything. Use `visibility: "homelab"`
only when the fact is true of both clusters, and you otherwise have to learn it twice.

| Fact                                                                | Goes to              |
| ------------------------------------------------------------------- | -------------------- |
| `miroir` replica settings, `apply-ks` suspend behaviour             | `homelab/home-infra` |
| openebs-zfs restore mechanics, the towonel edge                     | `homelab/home-infra` |
| Canonical Forgejo remote is `Exikle` with a capital E               | `homelab`            |
| "No Comments in Manifests" applies on both clusters                 | `homelab`            |
| The clusters differ. Artemis uses `miroir`, Frostlink `openebs-zfs` | `homelab`            |
| "prefers to confirm before merging to main"                         | `personal/exikle`    |

Use this test. If the sentence names the hardware or the storage layer of one cluster, it is
project-level. If it names a convention, a workflow, or a difference between the two clusters, it
goes to `homelab`.

### Known-open

- MCP connects can send no namespace. Claude Code runs the MCP `headersHelper` with the cwd set
  to the plugin root, so the plugin cannot find the project. Every MCP call then goes to the
  server default `homelab` (`MEMINI_DEFAULT_NAMESPACE`). The dotfiles wrapper
  `home/claude/scripts/memini-headers.sh` corrects this: it walks the ancestors to the first cwd
  outside the plugin cache and exports it as `CLAUDE_PROJECT_DIR`
  ([#2756](https://git.dcunha.io/Exikle/home-infra/issues/2756), closed).

    Make sure of the scope. Do not assume it. A recall hit with `namespace` `homelab` and no
    `from` field means that the MCP side resolved to `homelab` itself. The fallthrough is then
    back. The connect log `~/.cache/claude-cli-nodejs/<project>/mcp-logs-plugin-memini-memini/*.jsonl`
    must say "retrieved 3 headers". If it says 2, the client sent no namespace.

- A namespace with the name of a folder basename is the sign of a cwd probe that resolved to the
  wrong place ([#2757](https://git.dcunha.io/Exikle/home-infra/issues/2757), closed). Before you
  assume that the memories of a project are gone, read `GET /v1/namespaces`.

- The deployment sets `homelab/hermes`, not a pin. The hermes HelmRelease sets
  `MEMINI_NAMESPACE: homelab/hermes` (`kube/clusters/artemis/apps/cortex/hermes/app/helmrelease.yaml`).
  On 2026-10-20 the team moved it from a top-level `hermes`, so the agent reads the shared
  `homelab` facts. Its own writes stay in `homelab/hermes`. Only a `visibility: "homelab"` write
  reaches the parent that your sessions read.
- Promotion to `homelab` happens one fact at a time. The team promoted three seed facts by hand.
  The rest arrive when you write new cross-cluster lessons with `visibility: "homelab"`. A bulk
  curation pass is not necessary, and memini has no bulk move by filter.

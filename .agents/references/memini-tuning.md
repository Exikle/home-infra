# memini Recall and Write-Path Tuning

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

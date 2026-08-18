# Database — shared Postgres and surviving a restart

Frostlink runs **one** CNPG `Cluster/postgres` with `instances: 1`, fronted by `Pooler/pooler-rw`,
both in the `database` namespace. Onboarding, mTLS certs and the `postgres/cert` component are
covered in `.agents/instructions/cluster-conventions.md` § Database & Cache. This file is about
the other half: what happens to every client when that single instance goes away, and why the
settings that make it survivable look the way they do.

## Why the single instance restarts at all

`instances: 1` means there is no switchover — any change to the pod spec is a full outage, not a
failover. The routine trigger is Renovate bumping `Cluster.spec.imageName`: Flux reconciles, the
primary is recreated, and Postgres is unreachable for roughly two to three minutes. Three of
those landed in August 2026 alone, at arbitrary times of day.

This is expected and is not being engineered away. A second instance does not fit on one node,
so the design target is **clients that tolerate the blip**, not a database that never blips.

## The failure this caused (2026-08-17)

Both mautrix bridges died within seconds of every Postgres recreation:

```text
15:47:38Z  commit 3a38643 — Renovate bumps the CNPG image digest
15:52:31Z  postgres-1 recreated by Flux
15:52:44Z  mautrix-whatsapp exit 15        ← 13 seconds later
```

Exit 15 is SIGTERM, not 137 — this was never an OOM kill, and never memory pressure (the node
sits around 43% used with 13.4 GB free, and `postgres-1` itself uses ~204Mi). The pods were
created 2026-07-29 with restartCount 9 and 13, so these were **in-place container restarts**
inside long-lived pods, not rollouts.

### The amplifier: pgbouncer login-failure caching

The bridges mostly survived the outage itself and died on the **return edge**. pgbouncer caches
a failed server login and keeps serving that cached failure to clients for `server_login_retry`
seconds (default **15**). mautrix treats a DB error on init as fatal and exits, so it crash-looped
through the entire caching window — turning a ~170s database restart into three bridge restarts
each. That is what explains 9 and 13 restarts against only 3 image bumps; the probe was never the
main culprit.

Measured on a deliberate `postgres-1` delete:

| `server_login_retry` | signal restarts | whatsapp restarts |
| -------------------- | --------------- | ----------------- |
| `15` (default)       | 3               | 3                 |
| `1`                  | 2               | 1                 |
| `0`                  | **0**           | **0**             |

`0` disables the caching entirely, so the first query after recovery opens a real connection.
That is why `pooler.yaml` carries `server_login_retry: "0"` — it is **not** a stray tuning knob,
and raising it back toward the default reintroduces the crash loop.

## Settings that exist only for this, and must not be "tidied" back

| Where                                              | Setting                                     | Why |
| -------------------------------------------------- | ------------------------------------------- | --- |
| `apps/database/postgres/cluster/pooler.yaml`       | `server_login_retry: "0"`                   | Stops pgbouncer serving a cached login failure after the primary returns. At the default `15` the bridges crash-loop for the whole window. Measured: 3 restarts → 0. |
| `apps/matrix/mautrix-{signal,whatsapp}` helmrelease | `timeoutSeconds: 5`, `failureThreshold: 6`  | The liveness probe is a bare TCP connect with `periodSeconds: 30`. Unset, it defaults to a 1s timeout and 3 strikes — 90s of tolerance, less than one Postgres restart. Now 180s. |
| `.renovaterc.json5`                                | CNPG group, `schedule: ["* 4-6 * * 6"]`     | Batches the bumps that recreate the primary into one weekly window, so the outage is predictable and infrequent. It does not prevent it. |

A liveness probe should catch **deadlock**, not dependency outage — a database being briefly gone
belongs to readiness. The probes are kept, loosened, because the bridges do not currently prove
they recover from every wedged state on their own; the loosening is the conservative half of that
argument, not an endorsement of the probe.

## Verifying a change here

Delete the primary and watch the clients, which is the only test that actually exercises the path:

```bash
kubectl --context frostlink -n database delete pod postgres-1
kubectl --context frostlink -n matrix get pods -w
```

Done when `restartCount` on both bridges is unchanged once Postgres is Ready again. Verified this
way on 2026-08-18: `postgres-1` recreated at 00:57:55, both bridges still running since 00:52 with
restart counts flat.

## Still open

`kube-apiserver` is the node's largest single consumer at ~1980Mi with **no** memory limit. The
same shape caused OOM kills on Artemis. Not urgent at 43% node utilisation and unrelated to the
restart loop above, but it has not been decided either way. The CNPG `Cluster` also sets no
`resources` block, so `postgres-1` is BestEffort while the `Dragonfly` CR beside it is not.

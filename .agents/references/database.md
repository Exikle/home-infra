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

## Why `DatabaseRole.clientCertificate` cannot replace `components/postgres/cert`

Evaluated 2026-08-18 on mautrix-signal and rejected. CNPG 1.30 can issue and renew a client
certificate per role (`spec.clientCertificate.enabled`), which looks like it would delete the
cert-manager `Certificate` in `components/postgres/cert`. It cannot, for two independent
structural reasons. Neither is fixable inside the component.

**1. The client CA is bring-your-own, and CNPG will not sign without the key.** Enabling it live
returned:

```
client CA secret "postgres-client-ca" has no private key;
bring-your-own-CA clusters require manual certificate management
```

`database/postgres-client-ca` is a **trust-manager `Bundle` target** — it carries `ca.crt` only,
because the Bundle's source is `secret.key: tls.crt`. The CA keypair lives in
`cert-manager/postgres-client-ca` and stays there on purpose. Making CNPG issue would mean copying
the client CA **private key** into the `database` namespace, which is the separation trust-manager
exists to enforce.

**2. The secret lands in the wrong namespace.** `DatabaseRole.spec.cluster` is a
`LocalObjectReference` — name only, no namespace — so a `DatabaseRole` must live beside the
`Cluster` in `database`. CNPG writes the cert to `<databaserole-name>-client-cert` in *that*
namespace, but the pod that mounts it is in the app's namespace (`matrix`, `fediverse`, `tools`).
Secrets are namespace-scoped and no reflector/replicator is installed. cert-manager does not have
this problem because the `Certificate` is created by the app's own Flux Kustomization, so the
secret is already local to the pod.

Making this work needs both a CA-key relocation and a secret replicator — a change to the PKI trust
model, not a component refactor.

Two corollaries worth keeping:

- **The atuin `POSTGRES_CERT_ENCODING: PKCS8` exemption is moot.** `clientCertificate` exposes only
  `enabled`, with no encoding control, so atuin was expected to be the one app that could not
  migrate. In fact no app can, and for reasons that have nothing to do with encoding.
- **The naming mismatch is real but was never the binding constraint.** CNPG writes
  `<databaserole-name>-client-cert` while `components/postgres/base/patch` mounts
  `postgres-${APP}-cert`. Changing one without the other yields pods that start fine and fail at
  the TLS handshake. It only becomes relevant if the two blockers above are ever solved.

## Client certificates: CSI for most apps, Secrets for the mautrix bridges

Two mechanisms exist on purpose. `components/postgres/csi` mints the client
certificate into the pod at mount time via `csi.cert-manager.io`, so there is no
Secret and the cert rotates with the pod. `components/postgres/cert` keeps the
cert-manager `Certificate` plus a long-lived Secret. Shared wiring — the ksgate
scheduling gates, the `root-ca` mount, the connection-URL ConfigMap and the
`Database`/`DatabaseRole` — lives in `base/`, so the two differ only in how
`postgres-certs` is produced.

| App | Mechanism | Postgres driver |
| --- | --- | --- |
| atuin, gotosocial, apoci | `postgres/csi` | Rust sqlx-postgres 0.9.0; jackc/pgx v5.10.0 |
| mautrix-signal, mautrix-whatsapp | `postgres/cert` | lib/pq v1.11.2 |

**The bridges are not on CSI because of a lib/pq file-mode check, not anything
about CSI.** The driver mounts `tls.key` at `0440` root:`fsGroup`. lib/pq
v1.11.2 requires the owner write bit — `u=rw`, i.e. 0600 or 0640 — and rejects
0440 with:

```
pq: private key has world access; permissions should be u=rw,g=r (0640)
if owned by root, or u=rw (0600), or less
```

despite the "or less". Confirmed independent of CSI: a plain **Secret** at
`defaultMode: 0440` fails identically, and the same Secret at 0640 works. The
driver exposes `csi.cert-manager.io/fs-group` (group ownership only) and no
file-mode attribute, so 0440 cannot be changed; dropping `readOnly: true` does
not mount.

Before moving any app to `postgres/csi`, read its driver out of the binary and
confirm it is not lib/pq:

```bash
kubectl --context frostlink -n <ns> exec <pod> -c app -- \
  grep -a -o -E '(lib/pq|jackc/pgx)@?v[0-9.]*' <binary> | sort -u
```

lib/pq master has since relaxed the check to allow "0640 or less", so the
bridges can move once that reaches a mautrix release. m00nwtchr/homelab-cluster
runs mautrix-discord on CSI with an identical pod securityContext — that works
only because v0.7.6 predates lib/pq v1.11.2, so it is not evidence the bridges
would work here.

Two consequences worth keeping:

- **`POSTGRES_CERT_ENCODING` is retired from app config.** The CSI component
  pins PKCS8 for everyone, so atuin's PKCS8 exemption disappeared. The variable
  survives only as the PKCS1 default in `cert/certificate.yaml` for the bridges.
- **The `cert-manager` namespace is `pod-security.kubernetes.io/enforce:
  privileged`** so the CSI driver DaemonSet can mount hostPath and run
  privileged. That raises the ceiling in the namespace holding the PKI keys; a
  dedicated privileged namespace for the driver is the stricter alternative.

## CNPG PKI gotchas

Learned while standing the shared cluster up (2026-07-01) and still true of the live manifests.

- **The replication cert chains from the *client* CA, not the server CA.** CNPG verifies
  `certificates.replicationTLSSecret` against `clientCASecret` — replication is just another
  `clientcert=verify-full` client connection. Only `serverTLSSecret` verifies against
  `serverCASecret`. `cluster/certificate.yaml` issues `postgres-replication-cert` from the
  `postgres-client-ca` ClusterIssuer for exactly this reason, while `serverCASecret` is `root-ca`.
  Getting it backwards produces a confident-looking config that never connects.
- **CNPG does not watch a cert-manager secret it merely references.** It re-runs
  `setupPostgresPKI` on a Cluster-spec change or its own resync interval, not when an external
  secret's content changes. After any CA or issuer change the Cluster keeps reporting the stale
  `certificate signed by unknown authority` indefinitely. Force it:

  ```bash
  kubectl -n database annotate cluster postgres cnpg.io/reconciliationLoop="$(date +%s)" --overwrite
  ```

  **"Merely references" is doing the work in that sentence.** Every Certificate in
  `cluster/certificate.yaml` sets `secretTemplate.labels: {cnpg.io/reload: ""}`, and the live
  `postgres-server-cert` / `postgres-replication-cert` secrets carry it — that label is what makes
  CNPG watch a secret and push its **contents** to the instances, which is why a routine cert
  renewal needs no intervention. What it does not do is re-derive trust when the **CA or issuer**
  changes, which is the case the annotation above exists for. If you add a Certificate here, copy
  the `cnpg.io/reload` label with it; without it even a plain renewal is invisible until the next
  resync.
- **`spec.monitoring.enablePodMonitor` is deprecated on the CNPG API itself** — not in a particular
  chart release. `kubectl explain cluster.spec.monitoring.enablePodMonitor` returns "Deprecated:
  This feature will be removed in an upcoming release. If you need this functionality, you can
  create a PodMonitor manually." An earlier revision of this note said "deprecated in CNPG operator
  0.29.0"; **0.29.0 is the `cloudnative-pg` Helm chart version, and the operator it ships is
  1.30.0.** The two numbers version different things and neither is where the deprecation lives.
  The `PodMonitor` is created by hand instead — `cluster/podmonitor.yaml` and the second document in
  `cluster/pooler.yaml`, selecting on `cnpg.io/cluster: <name>`, port `metrics`. Do not "restore"
  the `enablePodMonitor` field. Artemis carries the identical rule against the identical
  1.30.0 / 0.29.0 pair.
- **The Pooler apply-time warning is benign.** `the operator won't handle the Pooler ...
  integration with the Cluster` is expected under the cert-auth pattern: the custom `authQuery`
  plus `auth_type: cert` means CNPG's automatic pooler-secret wiring never applies. Not a bug, and
  not something to silence by changing the Pooler.

## Still open

Deleting a `Certificate` does not delete its Secret. Four orphans remain, confirmed live
2026-08-21 — no `Certificate` object exists for any of them (`kubectl get certificate -A` lists
only the two CAs, the two `database` certs, and the two mautrix certs):

| Secret | Namespace | Age | Note |
| --- | --- | --- | --- |
| `postgres-apoci-cert` | `fediverse` | 51d | left by the move to `postgres/csi` |
| `postgres-gotosocial-cert` | `fediverse` | 51d | same |
| `postgres-atuin-cert` | `default` | 22d | from the namespace move |
| `postgres-atuin-cert` | `tools` | **4d** | unexplained — see below |

They are regenerable and safe to delete. **The `tools` one is 4 days old, which nothing here
accounts for** — atuin has been on `postgres/csi` (no Secret) for longer than that, so something
recreated it. Find out what before deleting it, or it will come back: check for a stray
`Certificate` in a suspended Kustomization, or an ExternalSecret writing the same name.

`kube-apiserver` is the node's largest single consumer — **1384Mi** as of 2026-08-21, down from
the ~1980Mi recorded earlier — with a `requests.memory` of 512Mi and **no limit**. The same shape
caused OOM kills on Artemis. Not urgent at 43% node utilisation (10179Mi of 24GB) and unrelated to
the restart loop above, but it has not been decided either way; re-read the number rather than
citing one, it moves with apiserver cache pressure. The CNPG `Cluster` sets no `resources` block at
all, so `postgres-1` is **BestEffort** (confirmed: `.status.qosClass`) while the `Dragonfly` CR
beside it is Burstable with a 512Mi limit. BestEffort is the first thing evicted under node memory
pressure, and on a single node that is a full database outage — the same outage this whole file is
about surviving.

## The shared Dragonfly exists and has no consumers

`Dragonfly/dragonfly` in `database` — `replicas: 1`, `limits.memory: 512Mi`,
`--proactor_threads=2`, `networkPolicyEnabled: true`, no auth, no persistence. It is the
cache/queue half of the shared data layer described in
`.agents/instructions/cluster-conventions.md` § Database & Cache.

**Nothing uses it today.** No manifest under `kubernetes/` references
`dragonfly.database.svc.cluster.local`, and `redis-cli INFO keyspace` reports `db0` with 0 keys
(2026-08-21). It is standing capacity for the next app that needs a cache, not a live dependency —
so a Dragonfly restart currently breaks nothing, and its `replicas: 1` is not the availability risk
`postgres`'s is.

Artemis runs the same shared Dragonfly with a per-app **DB-index allocation table** and reserves
index 0 as a forgot-to-configure tripwire. Frostlink has no such table because it has no consumers.
**Start one in this file the moment a second app is onboarded** — with one app the index does not
matter, and with two an unallocated index is a silent cross-app eviction.

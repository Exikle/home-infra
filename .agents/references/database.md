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

## Still open

Deleting a `Certificate` does not delete its Secret, so `postgres-atuin-cert`
(tools), `postgres-gotosocial-cert` and `postgres-apoci-cert` (fediverse) are
now orphaned and unreferenced. They are regenerable and safe to delete; the
`postgres-atuin-cert` in `default` is older, from the namespace move.

`kube-apiserver` is the node's largest single consumer at ~1980Mi with **no** memory limit. The
same shape caused OOM kills on Artemis. Not urgent at 43% node utilisation and unrelated to the
restart loop above, but it has not been decided either way. The CNPG `Cluster` also sets no
`resources` block, so `postgres-1` is BestEffort while the `Dragonfly` CR beside it is not.

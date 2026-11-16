# Database — shared Postgres and surviving a primary change

Frostlink runs **one** CNPG `Cluster/postgres` with `instances: 2` and
`primaryUpdateMethod: switchover`, fronted by `Pooler/pooler-rw`, both in the `database`
namespace. Onboarding, mTLS certs and the `postgres/cert` component are covered in
`.agents/instructions/frostlink.md` § Database and cache. This file is about the other
half: what every client sees when the primary changes, and why the settings that make that
survivable look the way they do.

Both instances run on the one node, so a node reboot still takes the whole database down. The
primary can move between the two pods, so never hardcode a pod name — select it:

```bash
kubectl --context frostlink -n database get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary
```

## Why clients must tolerate a primary change

The routine trigger is Renovate bumping `Cluster.spec.imageName`: Flux reconciles, the instances
are rolled and the primary switches over or is recreated, at arbitrary times of day. The design
target is **clients that tolerate the blip**, not a database that never blips.

The mautrix bridges used to die within seconds of every Postgres recreation. Exit 15 is SIGTERM,
not 137 — never an OOM kill or memory pressure. The pods were long-lived, so these were in-place
container restarts, not rollouts.

### The amplifier: pgbouncer login-failure caching

The bridges mostly survived the outage itself and died on the **return edge**. pgbouncer caches
a failed server login and keeps serving that cached failure to clients for `server_login_retry`
seconds (default **15**). mautrix treats a DB error on init as fatal and exits, so it crash-looped
through the entire caching window — each database restart became several bridge restarts.

Measured by deleting the primary, on the earlier one-instance cluster:

| `server_login_retry` | signal restarts | whatsapp restarts |
| -------------------- | --------------- | ----------------- |
| `15` (default)       | 3               | 3                 |
| `1`                  | 2               | 1                 |
| `0`                  | **0**           | **0**             |

`0` disables the caching entirely, so the first query after recovery opens a real connection.
That is why `pooler.yaml` carries `server_login_retry: "0"` — it is **not** a stray tuning knob,
and raising it back toward the default reintroduces the crash loop. The mechanism does not depend
on instance count; these numbers were not re-measured against a switchover.

## Settings that exist only for this, and must not be "tidied" back

| Where                                               | Setting                                    | Why                                                                                                                                                                             |
| --------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/database/postgres/cluster/pooler.yaml`        | `server_login_retry: "0"`                  | Stops pgbouncer serving a cached login failure after the primary returns. At the default `15` the bridges crash-loop for the whole window.                                      |
| `apps/matrix/mautrix-{signal,whatsapp}` helmrelease | `timeoutSeconds: 5`, `failureThreshold: 6` | The liveness probe is a bare TCP connect with `periodSeconds: 30`. Unset, it defaults to a 1s timeout and 3 strikes — 90s of tolerance, less than a Postgres restart. Now 180s. |
| `.renovaterc.json5`                                 | CNPG group, `schedule: ["* 4-6 * * 6"]`    | Batches the bumps that roll the primary into one weekly window, so the disruption is predictable and infrequent. It does not prevent it.                                        |

A liveness probe should catch **deadlock**, not dependency outage — a database being briefly gone
belongs to readiness. The probes are kept, loosened, because the bridges do not currently prove
they recover from every wedged state on their own; the loosening is the conservative half of that
argument, not an endorsement of the probe.

## Verifying a change here

Delete the primary and watch the clients, which is the only test that actually exercises the path:

```bash
kubectl --context frostlink -n database delete pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary
kubectl --context frostlink -n matrix get pods -w
```

Done when `restartCount` on both bridges is unchanged once Postgres is Ready again.

## Why `DatabaseRole.clientCertificate` cannot replace `components/postgres/cert`

Evaluated on mautrix-signal and rejected. CNPG can issue and renew a client certificate per role
(`spec.clientCertificate.enabled`), which looks like it would delete the cert-manager
`Certificate` in `components/postgres/cert`. It cannot, for two independent structural reasons:

1. **The client CA is bring-your-own, and CNPG will not sign without the key** ("client CA secret
   `postgres-client-ca` has no private key; bring-your-own-CA clusters require manual certificate
   management"). `database/postgres-client-ca` is a trust-manager `Bundle` target carrying
   `ca.crt` only; the CA keypair lives in `cert-manager/postgres-client-ca` on purpose. Making CNPG
   issue would mean copying the CA **private key** into `database`, which is the separation
   trust-manager exists to enforce.
2. **The secret lands in the wrong namespace.** `DatabaseRole.spec.cluster` has no namespace, so
   the role must live in `database`, and CNPG writes `<databaserole-name>-client-cert` there — but
   the pod that mounts it is in the app's namespace and no secret replicator is installed.
   cert-manager avoids this because the `Certificate` is created by the app's own Kustomization.

Solving both is a change to the PKI trust model, not a component refactor. Corollary: CNPG writes
`<databaserole-name>-client-cert` while `components/postgres/base/patch` mounts
`postgres-${APP}-cert`; changing one without the other yields pods that start fine and fail at the
TLS handshake.

## Client certificates: CSI for most apps, Secrets for the mautrix bridges

Two mechanisms exist on purpose. `components/postgres/csi` mints the client certificate into the
pod at mount time via `csi.cert-manager.io`, so there is no Secret and the cert rotates with the
pod. `components/postgres/cert` keeps the cert-manager `Certificate` plus a long-lived Secret.
Shared wiring — the ksgate scheduling gates, the `root-ca` mount, the connection-URL ConfigMap and
the `Database`/`DatabaseRole` — lives in `base/`, so the two differ only in how `postgres-certs`
is produced.

| App                              | Mechanism       | Postgres driver    |
| -------------------------------- | --------------- | ------------------ |
| atuin, gotosocial, apoci         | `postgres/csi`  | sqlx-postgres; pgx |
| mautrix-signal, mautrix-whatsapp | `postgres/cert` | lib/pq             |

**The bridges are not on CSI because of a lib/pq file-mode check, not anything about CSI.** The
driver mounts `tls.key` at `0440` root:`fsGroup`. lib/pq requires the owner write bit (`u=rw`, i.e.
0600 or 0640) and rejects 0440 with `pq: private key has world access; permissions should be
u=rw,g=r (0640) if owned by root, or u=rw (0600), or less`, despite the "or less". It is
independent of CSI: a plain **Secret** at `defaultMode: 0440` fails identically, and the same
Secret at 0640 works. The driver exposes `csi.cert-manager.io/fs-group` (group ownership only) and
no file-mode attribute, and dropping `readOnly: true` does not mount. lib/pq master has since
relaxed the check, so the bridges can move once that reaches a mautrix release.

Before moving any app to `postgres/csi`, read its driver out of the binary and confirm it is not
lib/pq:

```bash
kubectl --context frostlink -n <ns> exec <pod> -c app -- \
  grep -a -o -E '(lib/pq|jackc/pgx)@?v[0-9.]*' <binary> | sort -u
```

Two consequences worth keeping:

- **`POSTGRES_CERT_ENCODING` is retired from app config.** The CSI component pins PKCS8 for
  everyone. The variable survives only as the PKCS1 default in `cert/certificate.yaml` for the
  bridges.
- **The `cert-manager` namespace is `pod-security.kubernetes.io/enforce: privileged`** so the CSI
  driver DaemonSet can mount hostPath and run privileged. That raises the ceiling in the namespace
  holding the PKI keys; a dedicated privileged namespace for the driver is the stricter
  alternative.

## CNPG PKI gotchas

- **Changing a client cert's key encoding does not reissue it.** cert-manager treats
  `privateKey.encoding` alone as a no-op on an existing Certificate. Force it by patching an
  `Issuing: True` condition onto the Certificate's `.status`, which is what `cmctl renew` does.
  A rustls client (atuin) crashloops with `expected PKCS#8 PEM` until then.
- **A HelmRelease stalled on `RetriesExceeded` will not retry by itself** once the cert is
  fixed — clear it with `flux reconcile helmrelease <name> -n <ns> --reset --context frostlink`.
- **The replication cert chains from the _client_ CA, not the server CA.** CNPG verifies
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
    kubectl annotate cluster postgres -n database --context frostlink cnpg.io/reconciliationLoop="$(date +%s)" --overwrite
    ```

    **"Merely references" is doing the work in that sentence.** Every Certificate in
    `cluster/certificate.yaml` sets `secretTemplate.labels: {cnpg.io/reload: ""}` — that label is
    what makes CNPG watch a secret and push its **contents** to the instances, which is why a
    routine cert renewal needs no intervention. What it does not do is re-derive trust when the
    **CA or issuer** changes, which is the case the annotation above exists for. If you add a
    Certificate here, copy the `cnpg.io/reload` label with it; without it even a plain renewal is
    invisible until the next resync.

- **`spec.monitoring.enablePodMonitor` is deprecated on the CNPG API itself**
  (`kubectl explain cluster.spec.monitoring.enablePodMonitor --context frostlink`). The `PodMonitor` is created by
  hand instead — `cluster/podmonitor.yaml` and the second document in `cluster/pooler.yaml`,
  selecting on `cnpg.io/cluster: <name>`, port `metrics`. Do not "restore" the field.
- **The Pooler apply-time warning is benign.** `the operator won't handle the Pooler ...
  integration with the Cluster` is expected under the cert-auth pattern: the custom `authQuery`
  plus `auth_type: cert` means CNPG's automatic pooler-secret wiring never applies. Not a bug, and
  not something to silence by changing the Pooler.

## atuin

- `ATUIN_OPEN_REGISTRATION` **must stay `"false"`**: atuin is published on `external-gateway`, so
  open registration lets anyone create an account. Flip it true only long enough to run
  `atuin register`, then back.
- Auth is the cert path: sqlx accepts the libpq `sslcert`/`sslkey`/`sslrootcert` names the DSN
  carries, and the role is created with `disablePassword`.
- `/config` must be writable (an `emptyDir`) even with an external database: atuin writes a default
  `server.toml` on every start and aborts if it cannot. With `readOnlyRootFilesystem`, `/tmp` is an
  `emptyDir` too. There is no PVC — history lives in the shared Postgres.
- Port `8888` is atuin's own default; 80 would depend on Kubernetes lowering
  `net.ipv4.ip_unprivileged_port_start` for a uid-1000, all-caps-dropped container.

## The shared Dragonfly has no consumers

`Dragonfly/dragonfly` in `database` is the cache/queue half of the shared data layer
(`frostlink.md` § Database and cache): one replica, a memory limit, no auth, no
persistence. Nothing uses it today — `grep -rn 'dragonfly.database' clusters/frostlink/kubernetes` finds no
consumer — so a Dragonfly restart currently breaks nothing. Once a second app is onboarded, give
each app its own DB index and reserve index 0 as a forgot-to-configure tripwire; an unallocated
index is a silent cross-app eviction.

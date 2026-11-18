# Database — shared Postgres and surviving a primary change

Frostlink runs one CNPG `Cluster/postgres` with `instances: 2` and
`primaryUpdateMethod: switchover`. `Pooler/pooler-rw` sits in front of it. Both are in the
`database` namespace. The onboarding steps are in `.agents/instructions/frostlink.md` § Database
and cache. This file holds the reasons behind them. It also covers the other half: what every
client sees when the primary changes, and why the settings that let clients survive it look the
way they do.

Both instances run on the one node, so a node reboot still takes the whole database down. The
primary can move between the two pods. So never hardcode a pod name. Select the primary like this:

```bash
kubectl --context frostlink -n database get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary
```

## Why clients must tolerate a primary change

The usual trigger is a Renovate bump of `Cluster.spec.imageName`. Flux reconciles, the instances
roll, and the primary switches over or is recreated, at any time of day. The design target is
clients that survive the short break, not a database that never breaks.

The mautrix bridges used to stop within seconds of every Postgres recreation. Exit 15 is SIGTERM,
not 137. So it was never an OOM kill or memory pressure. The pods were long-lived, so these were
in-place container restarts, not rollouts.

### The amplifier: pgbouncer login-failure caching

The bridges mostly survived the outage itself. They stopped when the database came back.
pgbouncer caches a failed server login. It then gives that cached failure to clients for
`server_login_retry` seconds (default 15). mautrix treats a database error at startup as fatal and
exits. So it crash-looped through the whole caching window, and each database restart became
several bridge restarts.

Measured by deleting the primary, on the earlier one-instance cluster:

| `server_login_retry` | signal restarts | whatsapp restarts |
| -------------------- | --------------- | ----------------- |
| `15` (default)       | 3               | 3                 |
| `1`                  | 2               | 1                 |
| `0`                  | 0               | 0                 |

`0` turns the caching off. So the first query after recovery opens a real connection. That is why
`pooler.yaml` carries `server_login_retry: "0"`. It is not a stray tuning value. If you raise it
back toward the default, the crash loop comes back. The mechanism does not depend on the number of
instances. Nobody measured these numbers again against a switchover.

## Settings that exist only for this, and must not be "tidied" back

| Where                                               | Setting                                    | Why                                                                                                                                                                                    |
| --------------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/database/postgres/cluster/pooler.yaml`        | `server_login_retry: "0"`                  | Stops pgbouncer from giving a cached login failure after the primary returns. At the default `15`, the bridges crash-loop for the whole window.                                        |
| `apps/matrix/mautrix-{signal,whatsapp}` helmrelease | `timeoutSeconds: 5`, `failureThreshold: 6` | The liveness probe is a bare TCP connect with `periodSeconds: 30`. Unset, it uses a 1s timeout and 3 failures. That is 90s of tolerance, less than a Postgres restart. Now it is 180s. |
| `.renovaterc.json5`                                 | CNPG group, `schedule: ["* 4-6 * * 6"]`    | Puts the bumps that roll the primary into one weekly window. So the break is predictable and rare. It does not prevent the break.                                                      |

A liveness probe is for a deadlock, not for a dependency outage. A database that is gone for a
short time is a readiness matter. The probes stay, with looser values, because the bridges do not
prove that they recover from every stuck state on their own. The looser values are the careful
half of that argument. They do not mean that the probe is right.

## Verifying a change here

Delete the primary and watch the clients. This is the only test that runs the real path:

```bash
kubectl --context frostlink -n database delete pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary
kubectl --context frostlink -n matrix get pods -w
```

The test passes when `restartCount` on both bridges does not change after Postgres is Ready again.

## Why `DatabaseRole.clientCertificate` cannot replace `components/postgres/cert`

This was tried on mautrix-signal and rejected. CNPG can issue and renew a client certificate per
role (`spec.clientCertificate.enabled`). That looks like it removes the cert-manager `Certificate`
in `components/postgres/cert`. It cannot, for two separate structural reasons:

1. The client CA is bring-your-own, and CNPG does not sign without the key ("client CA secret
   `postgres-client-ca` has no private key; bring-your-own-CA clusters require manual certificate
   management"). `database/postgres-client-ca` is a trust-manager `Bundle` target. It carries
   `ca.crt` only. The CA keypair lives in `cert-manager/postgres-client-ca` on purpose. For CNPG to
   issue the certificate, you must copy the CA private key into `database`. trust-manager exists
   to prevent exactly that.
2. The secret lands in the wrong namespace. `DatabaseRole.spec.cluster` has no namespace, so the
   role must live in `database`. CNPG writes `<databaserole-name>-client-cert` there. But the pod
   that mounts it is in the namespace of the app, and no secret replicator is installed.
   cert-manager avoids this, because the Kustomization of the app makes the `Certificate`.

To solve both, you must change the PKI trust model. A component refactor is not enough. A related
trap: CNPG writes `<databaserole-name>-client-cert`, but `components/postgres/base/patch` mounts
`postgres-${APP}-cert`. If you change one without the other, pods start and then fail at the TLS
handshake.

## Client certificates: CSI for most apps, Secrets for the mautrix bridges

Two mechanisms exist on purpose. `components/postgres/csi` makes the client certificate inside the
pod at mount time, through `csi.cert-manager.io`. So there is no Secret, and the certificate
rotates with the pod. `components/postgres/cert` keeps the cert-manager `Certificate` and a
long-lived Secret. The shared wiring lives in `base/`: the ksgate scheduling gates, the `root-ca`
mount, the ConfigMap with the connection URL, and the `Database` and `DatabaseRole`. So the two
differ only in how they make `postgres-certs`.

To see which app uses which mechanism, run
`grep -rn components/postgres kube/clusters/frostlink/apps`. The mautrix bridges use `cert`,
because their Postgres driver is lib/pq.

The bridges are not on CSI because of a file-mode check in lib/pq. The cause is not CSI. The
driver mounts `tls.key` at `0440` root:`fsGroup`. lib/pq requires the owner write bit (`u=rw`,
that is 0600 or 0640). It rejects 0440 with `pq: private key has world access; permissions should
be u=rw,g=r (0640) if owned by root, or u=rw (0600), or less`, despite the "or less". A plain
Secret at `defaultMode: 0440` fails the same way, and the same Secret at 0640 works. The driver
offers `csi.cert-manager.io/fs-group` (group ownership only) and no file-mode attribute. If you
drop `readOnly: true`, the volume does not mount. The master branch of lib/pq has since relaxed
the check.

Before you move any app to `postgres/csi`, read its driver out of the binary. Make sure that it is
not lib/pq:

```bash
kubectl --context frostlink -n <ns> exec <pod> -c app -- \
  grep -a -o -E '(lib/pq|jackc/pgx)@?v[0-9.]*' <binary> | sort -u
```

Two results to keep in mind:

- `POSTGRES_CERT_ENCODING` is no longer an app setting. The CSI component pins PKCS8 for every
  app. The variable stays only as the PKCS1 default in `cert/certificate.yaml`, for the bridges.
- The `cert-manager` namespace is `pod-security.kubernetes.io/enforce: privileged`, so the CSI
  driver DaemonSet can mount hostPath and run privileged. That raises the limit in the namespace
  that holds the PKI keys.

## CNPG PKI gotchas

- A change to the key encoding of a client certificate does not reissue it. cert-manager treats a
  change to `privateKey.encoding` alone as a no-op on an existing Certificate. To force it, patch
  an `Issuing: True` condition onto the `.status` of the Certificate. `cmctl renew` does the same.
  A rustls client crashloops with `expected PKCS#8 PEM` until then.
- A HelmRelease stalled on `RetriesExceeded` does not retry on its own after the certificate is
  fixed. Clear it with `flux reconcile helmrelease <name> -n <ns> --reset --context frostlink`.
- The replication certificate chains from the client CA, not the server CA. CNPG verifies
  `certificates.replicationTLSSecret` against `clientCASecret`, because replication is one more
  `clientcert=verify-full` client connection. Only `serverTLSSecret` verifies against
  `serverCASecret`. For this reason, `cluster/certificate.yaml` issues `postgres-replication-cert`
  from the `postgres-client-ca` ClusterIssuer, while `serverCASecret` is `root-ca`. If you get it
  backwards, the configuration looks correct but never connects.
- CNPG does not watch a cert-manager secret that it only references. It runs `setupPostgresPKI`
  again on a change to the Cluster spec, or on its own resync interval. It does not run it when the
  content of an external secret changes. After any CA or issuer change, the Cluster keeps reporting
  the stale `certificate signed by unknown authority` with no end. Force it:

    ```bash
    kubectl annotate cluster postgres -n database --context frostlink cnpg.io/reconciliationLoop="$(date +%s)" --overwrite
    ```

    The words "only references" matter in that sentence. Every Certificate in
    `cluster/certificate.yaml` sets `secretTemplate.labels: {cnpg.io/reload: ""}`. That label makes
    CNPG watch the secret and push its contents to the instances. So a routine certificate renewal
    needs no action. The label does not make CNPG derive trust again when the CA or the issuer
    changes. The annotation above is for that case. If you add a Certificate here, copy the
    `cnpg.io/reload` label with it. Without the label, CNPG does not see even a plain renewal until
    the next resync.

- `spec.monitoring.enablePodMonitor` is deprecated in the CNPG API itself
  (`kubectl explain cluster.spec.monitoring.enablePodMonitor --context frostlink`). The
  `PodMonitor` is written by hand instead: `cluster/podmonitor.yaml` and the second document in
  `cluster/pooler.yaml`. Both select on `cnpg.io/cluster: <name>`, port `metrics`. Do not bring the
  field back.
- The apply-time warning on the Pooler is harmless. `the operator won't handle the Pooler ...
  integration with the Cluster` is expected with the cert-auth pattern. The custom `authQuery` and
  `auth_type: cert` mean that the automatic pooler-secret wiring of CNPG never applies. It is not a
  bug. Do not change the Pooler to silence it.

## The shared Dragonfly has no consumers

`Dragonfly/dragonfly` in `database` is the cache and queue half of the shared data layer
(`frostlink.md` § Database and cache). To find its consumers, run
`grep -rn 'dragonfly.database' kube/clusters/frostlink`. Today the command finds none. The rules
for DB indexes, including the reserved index 0, are in `postgres-dragonfly.md` § Onboarding an app
onto shared Dragonfly, which wins.

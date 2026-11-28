# Reference: Shared Postgres + Dragonfly — home-infra

The cluster has one shared CNPG Postgres cluster and one shared Dragonfly. Both are in the
`database` namespace. They are the default data layer for new apps. See
`.agents/instructions/cluster-conventions.md` § Deployment Philosophy.

Shared Postgres cluster: every app that carries `components/postgres/app`, with `APP` set in the
`postBuild` of its `ks.yaml`, is on it. This file has no roster on purpose, because the roster
changes with every onboarding. Run `grep -rln 'components/postgres' kube/clusters/artemis/apps/`
for the tree. Run `kubectl get database -n database --context artemis` for what actually reconciled.

Shared Dragonfly: the index table further down is the authoritative list of which app uses which
index.

Each further app migration is its own session. Use this doc when you do one.

## What's live

- Cluster: `postgres` in `database`. It has `instances: 2` (HA, `primaryUpdateMethod: switchover`).
  Both instances run on nodes in zone `pantheon` (VMs on one Proxmox host), so a pantheon outage
  takes both down. R2 is the copy that survives that. `.spec.imageName` is the live image. Renovate
  moves it, so do not trust a version written here. The cluster loads VectorChord through
  `postgresql.extensions`, so vector-search apps do not need a separate cluster fork. Here an image
  bump is a switchover. Clients see a short break in the connection, not an outage. Frostlink also
  runs two instances, on its one node, behind a pgbouncer Pooler. `database.md` wins for Frostlink.
- No pooler. Apps connect straight to `postgres-rw` with a password over TLS. Do not add a
  pgbouncer back unless you can point at a measured problem with the connection count. The old
  `poolMode: session` pooler gave no multiplexing. Its `pg_ident` map also let the pooler cert
  authenticate as any role.
- Dragonfly: `dragonfly` in `database`. It has 2 replicas (master and replica, with failover
  that the operator manages). It runs with
  `--cluster_mode=emulated --lock_on_hashtags --default_lua_flags=allow-undeclared-keys` so that
  most clients work with it. It has no auth and no persistence. For consumers, see the index table
  below.
- Backups: barman-cloud → Cloudflare R2 (`s3://artemis-kopiur/barman/`), with a daily schedule
  and on-demand `Backup` CRs. A restore from backup worked live (into a scratch cluster, which the
  team deleted after).
- CA chain on Artemis: the `postgres-server-ca` and `postgres-client-ca` ClusterIssuers in
  `cert-manager`. trust-manager `Bundle`s with the same names (`postgres-server-ca`,
  `postgres-client-ca`) distribute them. Run `kubectl get bundle -A --context artemis` to list the
  Bundles. Each Bundle output is a cluster-wide Secret that holds only the public cert. Never
  reflect the raw CA secrets (see Gotchas). Frostlink has its own Bundles. To list them, run
  `kubectl get bundle -A --context frostlink`. `database.md` wins for Frostlink.

## Onboarding an app onto shared Postgres

1. Wire the `ks.yaml` of the app to use the onboarding component:

    ```yaml
    components:
        - ../../../../components/postgres/app
    postBuild:
        substitute:
            APP: *app
    ```

    Use four `../`, not three. `../../../components/postgres/app` resolves outside the kustomize
    root, and the build fails. Every live consumer uses `../../../../`, the same depth as
    `../../../../components/kopiur/statefulset`.

    `PG_APP` is optional. It defaults to `${APP}`. Set it only when the database name is different
    from the app name. But every app must set `APP`, also an app that does not use kopiur. The
    envsubst of Flux is strict and evaluates both halves of `${PG_APP:=${APP}}`. An app that sets
    only `PG_APP` fails its whole post-build with `variable not set (strict mode): "APP"`. That
    failure also stops everything that has `dependsOn` on the app.

2. Add `components/postgres/tenants` to the namespace in
   `kube/clusters/artemis/apps/<ns>/kustomization.yaml`, in the same way as
   `components/kopiur/secret`. It creates one `ResourceSet` per namespace. That `ResourceSet`
   watches for the input providers that the app component emits. It templates the `DatabaseRole`
   CR, the `Database` CR and the role Secret into `database`.

    The `inputsFrom` of a `ResourceSet` selects providers in its own namespace only. For that
    reason the ResourceSet lives beside the apps and writes _across_ to `database`, not the
    reverse.

    There are two traps:

    1. A namespace that carries `tenants` with no app that uses it yet has a ResourceSet with zero
       inputs. `flate` then fails the _entire namespace_ with `map has no entry for key "name"`.
    2. Never name a component-generated input provider bare `${APP}`. An app can already own one
       with its own name (`cortex/memini` once did), so the postgres provider is `${APP}-postgres`.

    You cannot test the first postgres app in a namespace with `apply-ks` on the app alone. The
    `tenants` ResourceSet is a resource of the namespace. It belongs to the root Kustomization
    (`flux-system/flux-system`, path `./kube/clusters/<cluster>/apps`), not to the Kustomization of
    the app. `mise run //kube/clusters/artemis:apply-ks <ns> <app>` renders only the app path. The
    result:

    - The ResourceSet never appears.
    - No `Database` CR is templated, and no role Secret is created.
    - The pod of the app stays on the `k8s.ksgate.org/database-applied` scheduling gate forever.

    So apply the root as well: `mise run //kube/clusters/artemis:apply-ks flux-system
    flux-system`. It renders about 300 objects. All of them are control-plane objects
    (Kustomization CRs, namespaces, alerts, ExternalSecrets, Databases, ResourceSets). It has no
    HelmReleases and no workloads, so nothing restarts. First make sure that your checkout matches
    `origin/main`. If it does not, the apply silently reverts apps that you did not touch to your
    stale tree. You do not need this step for a second app in a namespace that already has
    `tenants`.

3. The component creates these objects in the namespace of the app:

    - A `ResourceSetInputProvider` (`<app>-postgres`).
    - A `<app>-postgres` Secret with the credentials and DSNs.
    - A `<app>-postgres` ConfigMap with the libpq SSL env.

    Through the namespace ResourceSet, it also creates three objects in `database`: a
    `DatabaseRole` CR named `<app>`, a `Database` CR named `<app>`, and a `<app>-postgres` role
    Secret.

    Connect with the Secret, not the ConfigMap. The Secret and the ConfigMap have the same name.
    The ConfigMap holds only the libpq SSL env (`PGSSLMODE`, `PGSSLROOTCERT`).

    There are three DSN keys, because three drivers do not agree. Pick the key by driver:

    | Key          | For                       | Shape                                                                        |
    | ------------ | ------------------------- | ---------------------------------------------------------------------------- |
    | `url`        | libpq, pgx, node-postgres | `?sslmode=verify-full&sslrootcert=<CA path>`                                 |
    | `url_node`   | postgres-js               | `?sslmode=verify-full` only. The CA comes from `NODE_EXTRA_CA_CERTS`         |
    | `url_prisma` | Prisma                    | `?sslmode=verify-full&sslcert=<CA path>`. Here `sslcert` means the root cert |

    `mise run //kube/clusters/artemis:check-postgres <ns> <app>` tests only the `url` key, on
    purpose. psql is libpq. It reads the Prisma `sslcert=` as a _client_ cert, and it has no CA at
    all for the postgres-js shape. A psql pass on those two keys gives false confidence about
    the failure below. All three keys carry the same credentials, host and database. So the check
    still proves the credential, the CA and `verify-full` for every app, whatever the driver. It
    cannot prove that an app uses the right key for its driver. It is a static check, not a
    connectivity check.

    A wrong key is a hard failure. postgres-js sends unknown connection-string parameters to the
    server as startup parameters. A libpq-shaped DSN then gets
    `unrecognized configuration parameter "sslrootcert"`, and the app never connects. This caused
    an outage of streamystats. Prisma does the opposite. It silently drops what it does not
    recognise, so a wrong DSN there fails _open_: it connects without verification.

    The Secret also holds discrete fields (`POSTGRES_HOST`/`PORT`/`DATABASE`/`USERNAME`/`PASSWORD`)
    for apps that take host, user and password separately and not as a URL.

    `<owner>` is `${DATABASE_OWNER}`, which defaults to `${PG_APP:=${APP}}`. Set it only when the
    role name is different from the database name.

### Roles are templated, not listed

Roles moved out of `spec.managed.roles` in `cluster.yaml` on 2026-09-02. The `postgres-tenants`
ResourceSet now emits them as `DatabaseRole` CRs, one per tenant. When you add or remove an app,
there is nothing to edit in `cluster.yaml`. The input provider that the app component emits is the
only place that declares a tenant. The `managed` stanza is gone from the Cluster entirely.

`DatabaseRole` is a CNPG 1.30 CRD. Know these three facts before you touch one:

- It adopts, and adoption is destructive to omitted attributes. If you point a `DatabaseRole` at a
  role that already exists, it rewrites _every_ attribute to match the manifest. This includes the
  attributes that the manifest does not mention. It revokes memberships that are not in
  `inRoles`. An omitted `connectionLimit` resets to `-1`, and an omitted `validUntil` becomes
  `infinity`. The template is minimal on purpose (`login`, `superuser`, `passwordSecret`),
  because every tenant role is minimal. If a role needs `inRoles` or a connection limit, the
  template must have it. If it does not, the next reconcile removes it.
- `databaseRoleReclaimPolicy: retain` is set explicitly and must stay that way. If you delete the
  `ks.yaml` of an app, that removes its input provider, which removes the `DatabaseRole`. Under
  `delete`, CNPG then tries a `DROP ROLE`. Under `retain`, the role and everything it owns stay.
  The default is already `retain`, but the manifest writes it out. This field is the only thing
  between a manifest deletion and data loss, and manifests here carry no comments to say so.
- It does not repair drift the way the inline stanza did. CNPG reconciles a `DatabaseRole` when
  its spec or its password Secret changes. It does not find or revert a manual `ALTER ROLE` in the
  database. CNPG compared inline `managed.roles` against the catalogue at intervals. Now, drift
  from a hand edit of a role in psql stays.

If a role name is declared in both places at once, the Cluster spec wins. The `DatabaseRole` then
reports `status.applied: false` with `database role is already managed by the CNPG
cluster`. That message means that a stale `managed.roles` entry came back.

4. The pod does not start until Postgres is ready. The component adds `ksgate`
   (`k8s.ksgate.org/*`) scheduling gates. The pod of the app stays `SchedulingGated` until all of
   these are true:

    - The shared Cluster has at least 1 ready instance.
    - The `postgres-rw` Service exists.
    - The `Database` CR of the app shows `status.applied: true`.

    This is expected. It is not a stuck pod.

5. Some apps keep the DSN in a config file on their PVC. That wiring is not in git, because the
   HelmRelease does not configure the app at all. For example, `recorder.db_url` of Home Assistant
   lives in `/config/configuration.yaml` on the PVC. Follow these steps:

    1. Inject the DSN as an env var from the component Secret.
    2. Reference the env var from the config file (HA: `db_url: !env_var RECORDER_DB_URL`), so
       that the credential never lands on disk.
    3. Keep a backup of the pre-migration config beside it (`configuration.yaml.pre-postgres`).
    4. After a PVC restore on such an app, look at the config again.

    Know the consequence. If you restore that PVC from a kopiur snapshot from before the
    migration, the app silently goes back to its old database. No manifest change shows it. The
    HelmRelease still passes the DSN in, and the app ignores it.

## There are no pgbouncer sidecars

Do not add one back to solve a TLS problem. Solve it with the right DSN key from the table above.
Servarr has no `SslMode` option, but Npgsql negotiates TLS against a `hostssl` line anyway.
`pg_stat_ssl` reports `ssl=t` for the role.

Servarr logs its connection string, password included, at Info level on every startup
(`MigrationController: *** Migrating Database=...;Password=... ***`). Pod logs go to
VictoriaLogs. The fleet currently shares one password, so that one log line is the credential for
every role. The team accepted this on purpose for a LAN homelab. Remember it before you treat
log access as low-sensitivity.

### CR-based apps get the Database CR, but not the pod patch

`components/postgres/app/patch` targets `kind: HelmRelease` only. An app that is deployed as a
custom resource still gets everything that the ResourceSet makes: the `Database` CR, the role
Secret, its own input provider and the Secret in the namespace of the app. These are plain
resources, not patches. The app does not get the ksgate scheduling gates or the server-CA volume
mount.

So a CR app declares its own mount. `security/pocket-id` (a `PocketIDInstance`) does. If an app
does not have the mount, nothing tells you: `verify-full` has no CA to check against.

A HelmRelease can also opt out of the gates and the mount. The patch skips any HelmRelease that
carries the annotation `postgres.dcunha.io/skip-patch` (`annotationSelector` in
`components/postgres/app/patch/kustomization.yaml`).

## Onboarding an app onto shared Dragonfly

This is a config cutover only. It needs no data migration and no kustomize component. Dragonfly is
a cache with no auth and nothing to provision per app. It also has no scheduling gate, on
purpose. Postgres is a hard dependency, because the `Database` CR and the role password of the app
must exist before the app can authenticate. A cache is a soft dependency, and Redis-protocol
clients already retry and reconnect on their own. The design follows
[mortebrume/homelab](https://github.com/mortebrume/homelab), which runs 8 apps against a shared
Dragonfly this way with no gates.

1. Claim the next unused index from the table below and add a row for the app. Index `0` is
   reserved and never assigned. A pod that did not configure an index silently uses `0`. The
   mistake is then obvious at once, and it does not collide with a real app.

    This table is an allocation registry, not a derived list. An index that is held for an app
    that has not configured it yet exists nowhere else, so `grep` cannot find it. The table does
    not record key counts, on purpose. `redis-cli INFO keyspace` (below) gives them live.

    | Index | App                                     | Where the index is set                     |
    | ----- | --------------------------------------- | ------------------------------------------ |
    | 0     | _(reserved, never assign)_              | —                                          |
    | 1     | paperless                               | `PAPERLESS_REDIS` URL suffix `/1`          |
    | 2     | immich                                  | `REDIS_DBINDEX: "2"` (app + microservices) |
    | 3     | renovate (package cache)                | `RENOVATE_REDIS_URL` suffix `/3`           |
    | 4     | _(free)_                                | —                                          |
    | 5     | trawl (Cloudflare bypass session cache) | `REDIS_URL` suffix `/5`                    |
    | 6     | silo                                    | `REDIS_URL` suffix `/6`                    |

    Index 3 was claimed by litellm, which never set it. litellm no longer exists, and Renovate took
    the index on 2026-11-21. Index 4 held tekton-runner checkpoints until 2026-10-27. tekton-runner
    no longer exists.

    Use the keyspace to make sure that an app uses its index. The manifest can be wrong, but the
    keyspace cannot:

    ```bash
    kubectl -n database exec dragonfly-0 -c dragonfly --context artemis -- redis-cli INFO keyspace
    ```

2. Point the Redis or cache env of the app directly at
   `redis://dragonfly.database.svc:6379/<index>`. If the app does not take a single URL, use its
   host, port and db-index fields.
3. Remove the old sidecar or embedded Redis or Valkey container, its config, and any PVC it had.
   Dragonfly needs none of that.
4. Add the namespace of the app to `dragonfly-clients`
   (`kube/clusters/artemis/apps/database/dragonfly/cluster/networkpolicy-clients.yaml`).

    The dragonfly-operator generates its own `dragonfly` NetworkPolicy. The Dragonfly CR owns it,
    so you cannot manage it from git. Its 6379 ingress rule is a bare `podSelector: {}`. That means
    "this namespace only", and it drops every client from another namespace. NetworkPolicies
    union, so `dragonfly-clients` is what widens it. If you skip this step, the app fails with
    connect timeouts, not refusals. The symptom does not point at a policy.

## R2 backup sizing — why the WAL settings are what they are

An audit on 2026-08-05 found that WAL, not base backups, was about 73% of the `artemis-kopiur`
bucket. The whole `postgres` cluster holds only about 320 MB of actual data across all databases.
It generated about 2.2 GiB of WAL per day. That is about 7× the entire database, every day.

`pg_stat_wal` gave the cause. 942,903 full-page images made up about 90% of 7.36 GB of
`wal_bytes`. Postgres writes a full 8 KiB page image the first time a page changes after each
checkpoint. `checkpoint_timeout` was at the 5-minute default. 727 of 736 checkpoints were timed,
not caused by size. So Postgres wrote a small working set that changes all the time into WAL 288
times a day. `checkpoint_timeout: 30min` is the fix that actually reduces bytes, because it cuts
how often Postgres writes those page images again. `max_wal_size: 2GB` is headroom. It keeps the
checkpoints timed, so that they do not become size-driven at the longer interval.

The team did not enable `wal_compression`, on purpose. It compresses full-page images inside the
WAL record. But the ObjectStore already applies `wal: compression: zstd` to the whole segment, and
that gets nearly the same ratio. The segments already compressed about 5:1 (16 MiB → 2-4 MiB). If
the team turns it on, it mostly moves the compression earlier. It does not shrink what
lands in R2. Consider it again if local `pg_wal` volume or replication bandwidth becomes the
problem.

WAL now lives on its own 8Gi volume (added 2026-09-01, #1916). A stalled archive fills that volume,
not the data volume, and `CNPGWalArchiveBacklog` pages before it matters.

`archive_timeout: 900s` controls the number of objects, not the number of bytes. It forces a
segment upload even when the segment is not full. The old 300s value therefore put a hard floor of
288 uploads a day under the bucket, whatever the activity. That is why WAL objects outnumbered
everything else 100:1. The unused tail of a force-switched segment is zero-padding that compresses
to almost nothing. So a higher value saves operations far more than storage. The cost is off-site
RPO: R2 can now be up to 15 minutes stale. Local durability does not change. `postgres` runs
`instances: 2` with streaming replication, so R2 is the copy for when both nodes are lost. It is
not the first line of recovery.

Retention on the `r2-store` ObjectStore is `7d`.

### Orphaned prefixes are never reclaimed by `retentionPolicy`

Barman expires only servers that it still manages. A prefix of a retired cluster therefore stays
in R2 forever, with no ObjectStore, Cluster or repo reference that points at it. After a
major-version migration or a restore test, delete the old prefix by hand. Nothing in the cluster
does it for you.

The bucket must contain exactly one prefix, `barman/postgres/`. Make sure of this against a live
listing before you believe any inventory in this file:

```bash
kubectl run r2ls -n database --rm -i --restart=Never --image=amazon/aws-cli:latest \
  --env=AWS_ACCESS_KEY_ID="$(kubectl get secret -n database barman-r2 -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)" \
  --env=AWS_SECRET_ACCESS_KEY="$(kubectl get secret -n database barman-r2 -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)" \
  --env=AWS_DEFAULT_REGION=auto \
  -- s3 ls s3://artemis-kopiur/barman/ --endpoint-url https://cb8e9b25dc436d997f232269a3597c61.r2.cloudflarestorage.com
```

The workstation has no `r2:` rclone remote, so `rclone` recipes for this bucket do not work as
written. Go through the `barman-r2` Secret as above.

The gate for a purge is a backup, not a waiting period. The old prefix stops being the rollback
when the _new_ lineage holds a base backup that actually contains the app. Take an on-demand
backup. Do not wait for the nightly one:

```bash
kubectl create -f - <<'MANIFEST'   # the cnpg kubectl plugin is not installed
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: postgres-post-<app>-migration, namespace: database }
spec:
  cluster: { name: postgres }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
MANIFEST
```

Make sure that it landed by its size, not only by its timestamp. The post-immich backup grew from
150.6 MiB to 604.3 MiB, which matches the 527 MB database of immich. If a base backup did not
grow, it did not pick up the app.

One fact made the immich rollback worth less than it looked: a barman prefix holds only the
database. The Immich library is NFS on atlas (`/mnt/atlas/media/photos`). A restore of an old
prefix puts the metadata out of sync with the files already on disk. Before you keep a
prefix, weigh it against what it can actually restore.

## Dedicated CNPG clusters — there are none

A per-app `Cluster` is not the default, and has not been since 2026-07-02. The old `cnpg-database`
skill taught "one Cluster per app, never shared" with `username`/`password` ExternalSecrets. The
shared cluster above replaces that policy. The team retired the skill on 2026-08-21.

The fleet has exactly one CNPG `Cluster`. `kubectl get cluster -A --context artemis` lists it. Read
`.spec.imageName` for the live version, because Renovate moves it. Storage is `40Gi` data + `8Gi`
WAL, with the `r2-store` ObjectStore at `s3://artemis-kopiur/barman/`.

### Check the shared cluster before forking one

The shared cluster loads VectorChord through `postgresql.extensions`, not through a forked base
image. So it usually already has what an app needs. One query on the primary settles it:
`SELECT name, default_version FROM pg_available_extensions`. If you must fork, follow these rules:

- Say why in the commit.
- Give the new cluster its own `walStorage`.
- Connect through `<name>-rw`.

The R2 prefix is fixed when the cluster is created. If you rename the Cluster, the whole barman
server becomes an orphan (see § Orphaned prefixes).

### What the immich migration actually took

This list is here because the next consolidation will look the same:

- Create the extensions before the restore. The tenants template has no `extensions` field (see
  Gotchas), so run `CREATE EXTENSION` by hand on the new database. A dump loads index
  definitions that reference extension types. Without the extensions, the restore fails midway.
- Use dump and restore, not logical replication. It rebuilds the vector indexes, which you want
  across a pgvector version change anyway.
- Make sure that the vector index works, not only the row counts. Run `EXPLAIN` on a
  nearest-neighbour query and look for an `Index Scan`, not a `Seq Scan`. VectorChord also needs
  `SET vchordrq.probes` in the session. Without it, the query stops with
  `need 1 probes, but 0 probes provided`. Immich sets that session setting itself, so the error
  does not mean a broken index.
- Raise the startup budget of the app first. A database migration is another cold start.
  Migrations can take longer than a short startup probe allows, and the pod then restart-loops.

### Retiring an app's own Postgres leaves its PVC behind

The migration off per-app databases deletes the StatefulSet, not the claim. `miroir` is
`reclaimPolicy: Delete`, but that applies only when the PVC is deleted. Nothing references an
orphaned claim. The cluster keeps it forever, it costs one copy per replica, and it looks the same
as a healthy one in `kubectl get pvc`. Delete the PVC as the last step of any migration off a
per-app database.

`storage.md` § Orphaned PVCs keeps the live orphan inventory in one place only. It also has the
pod-volume diff that finds them. The team reclaimed the seven that it missed before on 2026-09-01
under [#1889](https://git.dcunha.io/Exikle/home-infra/issues/1889).

### The PVC is one of four things a retirement leaves behind

The #1889 audit found the same shape four times. Flux prunes the declarative object, and the
object that holds the bytes stays, by design. When you retire an app from the shared cluster, look
at all four, not only the PVC:

| Left behind            | Why it stays                                                                                    |
| ---------------------- | ----------------------------------------------------------------------------------------------- |
| The PVC                | `reclaimPolicy: Delete` applies when the PVC is deleted, not when the StatefulSet is deleted    |
| The database           | `databaseReclaimPolicy: retain` is the CNPG default. The `Database` CR goes, the database stays |
| The client-cert Secret | cert-manager does not delete a Secret when its `Certificate` is pruned                          |
| The barman R2 prefix   | `retentionPolicy` only expires servers that barman still manages (see § Orphaned prefixes)      |

The trap is that `databaseReclaimPolicy: retain` is the default. Every app that you remove from the
shared cluster leaves its database behind, unless you drop it explicitly. Find the primary first,
because it moves on switchover:

```bash
kubectl get pods -n database -l cnpg.io/cluster=postgres,role=primary --context artemis
```

A hand-made `Backup` CR is a fifth, rarer case. A `ScheduledBackup` owns the Backups that it
creates (`backupOwnerReference: self`), so those Backups go when the ScheduledBackup goes. A
Backup that you create by hand has no owner reference, so it stays. Deleting that CR does not
touch the R2 data.

Set up a dedicated cluster only when the app cannot share. Examples are an extension that the
shared cluster does not load, a major-version pin, or a hard isolation requirement. Say why in the
commit. If you do, follow these rules:

| Rule                                | Why                                                                                                                                                                                                                        |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always give it its own `walStorage` | If WAL shares the data disk and archiving lags (or is not configured), WAL fills the data PVC and the pod goes into CrashLoopBackOff. A separate volume turns a cluster-down event into a warning about a stalled archive. |
| Connect via `<name>-rw`             | CNPG creates `<name>-rw` (read-write) and `<name>-ro` for you. `<name>` alone is not a Service.                                                                                                                            |
| Back it up with barman              | Use the barman-cloud plugin, as the shared cluster does (`plugins` in its `cluster.yaml`). The kopiur component backs up an app StatefulSet claim, not a CNPG PVC.                                                         |

### Common issues — dedicated or shared

| Symptom                          | Cause                                                                        | Fix                                                                                                                                                                                                               |
| -------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pod stuck `Pending`              | `miroir` PVC not bound (WaitForFirstConsumer needs a consumer)               | Look at the miroir agent and CSI pods in `miroir-system`                                                                                                                                                          |
| `role "<app>" does not exist`    | The `DatabaseRole` CR has not reconciled yet                                 | `kubectl -n database get databaserole <app> --context artemis -o yaml`. Read `status.applied` and `status.message`                                                                                                |
| `password authentication failed` | Stale or wrong `POSTGRES_PASSWORD` in the `<app>-postgres` secret of the app | Force-sync the ExternalSecret. Then run `mise run //kube/clusters/artemis:check-postgres <ns> <app>` to test the credential. It connects with the `url` DSN of the Secret, so it tests what the app actually uses |
| WAL directory fills              | No separate `walStorage` volume                                              | Add `walStorage` and apply again                                                                                                                                                                                  |
| Cluster stuck `Initializing`     | CRD not installed                                                            | `kubectl get crd clusters.postgresql.cnpg.io`                                                                                                                                                                     |
| App can't connect                | Wrong Service name                                                           | `postgres-rw.database.svc.cluster.local` for shared. `<name>-rw` for dedicated                                                                                                                                    |

## Gotchas

- `xbrowsersyncgo` runs as `PG_APP: signet`. Its database, role and `signet-postgres` secret keep
  the old app name, Signet. If you rename them, the app starts on an empty database.
- The `Database` template of the `postgres-tenants` ResourceSet has no `extensions` field, so the
  component cannot create extensions. Use one of two ways:
    - Run `CREATE EXTENSION` once as superuser on the database of the app, right after the
      `Database` CR applies. Extensions persist, and barman backups are physical, so the
      extensions survive restores.
    - Own a `Database` CR with `spec.extensions`, as `kritika` does
      (`kube/clusters/artemis/apps/kritika/kritika/database/database.yaml`).
- Do not remove old-DB keys from the ExternalSecret of the app in the same cutover apply. If the
  new pods do not go ready, helm-controller rolls back to the previous release. The pods of that
  release still use `envFrom` on the secret. With the old `DATABASE_URL` and password gone, the
  rollback itself crashloops and gets stuck (`pending-rollback`). Keep the old keys in the ES
  template until the new release goes `Ready` once. Then remove them in a follow-up apply. Do not
  patch the _secret_ directly, because ESO reverts drift on owned secrets within seconds. If you
  need a temporary shim, patch the ExternalSecret spec.

- All apps share one Dragonfly memory budget (`resources.limits.memory` in
  `kube/base/database/dragonfly/cluster/dragonfly.yaml`). There is no per-app
  quota. A DB index only prevents key collisions. It does not stop one app from evicting the keys
  of another. If the working set of one app fills the cache, Dragonfly can evict keys from the DB
  index of any other app.
- Never reflect a cert-manager `isCA: true` secret cluster-wide. It contains `tls.key`, the
  private signing key of the CA, beside `ca.crt`/`tls.crt`. Distribute only the public cert,
  through a trust-manager `Bundle` that copies `tls.crt` into a secret that holds only `ca.crt`.
- `Cluster.spec.certificates.serverCASecret` must reference a secret in the namespace of the
  Cluster that contains only `ca.crt`. Point it at the trust-manager bundle output
  (`postgres-server-ca`), never at the raw CA secret name. A wrong value gives
  `Warning SecretNotFound` from cloudnative-pg. `Cluster.status.conditions[Ready]` then changes to
  `False`/`ClusterIsNotReady`, even though the pods stay `Running`.
- `monitoring.enablePodMonitor` is deprecated on `Cluster`/`Pooler`. Write a `PodMonitor` by hand
  (`cnpg.io/cluster: postgres` selector) instead. The deprecation is in the CNPG API, not in a
  chart version: `kubectl explain
  cluster.spec.monitoring.enablePodMonitor` says "Deprecated: This feature will be removed in an
  upcoming release. If you need this functionality, you can create a PodMonitor manually." The
  operator and the `cloudnative-pg` chart have separate versions. Do not mix them up.
- The ScheduledBackup cron runs in the local timezone of the pod (k8tz), not UTC. To test, start
  an on-demand `Backup` CR. Do not assume that a schedule is overdue.

## atuin

atuin is the shell history sync server, `default/atuin` at `atuin.dcunha.io`. It moved from
Frostlink on 2026-11-17 with a `pg_dump` and `pg_restore` of its database.

- `ATUIN_OPEN_REGISTRATION` must stay `"false"`. atuin is public on `edge-gateway`, so open
  registration lets anyone make an account. Set it to `"true"` only while you run
  `atuin register`, then set it back.
- `/config` must be writable (an `emptyDir`), even with an external database. atuin writes a
  default `server.toml` at each start and stops if it cannot. With `readOnlyRootFilesystem`, `/tmp`
  is an `emptyDir` too. There is no PVC. The history lives in the shared Postgres, so the CNPG
  backups cover it.
- Port `8888` is the default of atuin. Port 80 needs Kubernetes to lower
  `net.ipv4.ip_unprivileged_port_start` for a uid-1000 container with all capabilities dropped.
- The clients sync over the internet, so CrowdSec exempts the host from the bot challenge
  (`crowdsec.md`).

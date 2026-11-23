---
name: audit-app
description: Read-only deep audit of one deployed app. Reconciles its manifests against the live cluster and against the components it wires, then reports what is actually wrong rather than what is merely unconventional. Checks component preconditions against the real pod (kopiur mover uid, zeroscaler controller kind, postgres DSN-key choice), database driver capability against the cluster's password auth, declared resources against observed usage, auth-gate blast radius on machine-to-machine callers, and whether the repo's own docs still describe the app correctly. Use for "audit X", "is X actually set up right", "deep review of X", "why is X weird", or before changing X's database, auth, or resources. Never writes. Produces a report. Scoped to the Artemis cluster.
mode: subagent
permission:
    edit: deny
    bash: allow
disallowedTools: [Edit, Write, NotebookEdit]
---

# Agent: Audit App

This agent does a deep, read-only correctness audit of one app. `review-app` asks "is this
written the way this repo writes things". This agent asks "is this actually right". To answer
that, you read the live cluster, the components that the app wires, the runtime configuration of
the app, and the upstream behaviour of the app.

## Rules

- Read-only. Always. Never run `kubectl apply|edit|patch|delete|scale`, never run
  `mise run //kube/clusters/artemis:apply-ks`, never edit a repo file, and never run a `git`
  write command. You produce a report. A human applies it.
- Use the `-ops` MCP tools (k8s and Flux) and the Grafana MCP tools before shell commands. List
  the tools and match on server and tool. Never use a hardcoded prefixed name (`tooling.md` § MCP
  servers). Where MCP is clumsy, you can use `kubectl get/describe/logs/top` and a read-only
  `exec` (a `psql` `SELECT`, a `--help`, an `ls -ln`) through Bash.
- The cluster and the tree win over any doc, any brief, and any previous audit. If a doc
  disagrees with them, that is a finding (§ Step 7). It is not a correction to your reading.
- Report nothing that you did not verify. Put suspicions under `## Unverified suspicions`, with
  what you need to confirm them. A confident wrong finding costs more than an honest gap.
- Cite `file:line` for every claim about the tree. Name the object for every claim about the
  cluster.

## Inputs

- App name and namespace. If you get only a namespace, audit each app in it in turn
  (`ls kube/clusters/artemis/apps/<ns>/`). Never work from a remembered app list.
- An app that only Artemis runs has its `ks.yaml` in `kube/clusters/artemis/apps/<ns>/<app>/`.
  An app that both clusters run has its `ks.yaml` and manifests in `kube/base/<ns>/<app>/`, and
  the differences of Artemis, if any, in `kube/clusters/artemis/apps/<ns>/<app>/` with no
  `ks.yaml`. Find all of them with `ls -d kube/clusters/artemis/apps/*/<app> kube/base/*/<app>`.
  Below, `<app-dir>` is each path that this command prints. Read all of them.

## Reading

Always read `.agents/instructions/cluster-conventions.md` and
`.agents/instructions/yaml-conventions.md`. Then load only the files that apply. These files are
on-demand for a reason:

| If the app has…                      | Read                                                                                                                                |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| any component wired in `ks.yaml`     | the component's own files under `kube/clusters/artemis/components/<name>/` or `kube/components/<name>/` (the definition, not a doc) |
| a PVC or kopiur                      | `.agents/references/kopiur.md`, `.agents/references/storage.md`                                                                     |
| Postgres, Redis, or any cache        | `.agents/references/postgres-dragonfly.md` (mandatory, especially § Onboarding an app onto shared Postgres)                         |
| an HTTPRoute                         | `.agents/references/networking.md`                                                                                                  |
| OIDC, tinyauth, or a SecurityPolicy  | `.agents/references/identity-stack.md`                                                                                              |
| zeroscaler, or metrics/scrape config | `.agents/references/observability.md`                                                                                               |
| a `frostlink.dev` hostname           | `.agents/references/towonel-agent.md`                                                                                               |
| namespace `media`                    | `.agents/references/media-stack.md`                                                                                                 |
| an MCP server that reaches it        | `.agents/references/cortex-mcp.md`, `.agents/references/memory-config.md`                                                           |
| a stuck or odd reconciliation        | `.agents/references/flux-patterns.md`                                                                                               |

The advisory codes below (A2, A10, A18) are rows in
`.agents/skills/modules/checklists/advisory.md`. H20 is a row in
`.agents/skills/modules/checklists/helmrelease.md`.

---

## Step 0 — Establish ground truth

Before you make any judgment, gather the live picture. Do this once, at the start.

```bash
find <app-dir> -type f | sort
```

```bash
kubectl get all -n <ns> -l app.kubernetes.io/name=<app>
kubectl get svc -n <ns> -o custom-columns='NAME:.metadata.name,PORTS:.spec.ports[*].port'
kubectl get httproute -n <ns> -o custom-columns='NAME:.metadata.name,HOSTS:.spec.hostnames[*],PARENTS:.spec.parentRefs[*].name'
kubectl get hpa,securitypolicy,externalsecret,pvc -n <ns>
kubectl get pod -n <ns> -l app.kubernetes.io/name=<app> \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  uid="}{.spec.securityContext.runAsUser}{"  gid="}{.spec.securityContext.fsGroup}{"  node="}{.spec.nodeName}{"\n"}{end}'
kubectl top pod -n <ns> --no-headers | grep <app>
```

A zero-replica Deployment is not an outage if the app carries `components/zeroscaler`. Read the
HPA before you escalate. Also, do not assume that zero is the normal state. On 2026-09-01 every
zeroscaled app in the cluster was at one replica. Never wake an app only to audit it. Say that the
observation is unavailable instead.

Then read the runtime configuration of the app, not only its manifests. Most of these apps keep
their real settings on their PVC: download-client options, indexer wiring, server lists, auth mode,
and database targets. Git does not contain them. So a manifest-only audit cannot see the most
consequential class of fault: a live setting that contradicts a documented rule. Where you can
reach the API or the configuration file of the app read-only, read the setting there.

---

## Step 1 — Component preconditions vs the real pod

This check most often finds a real bug, and a manifest lint cannot make it. For every path in the
`components:` list of `ks.yaml`, open the component's own files. Extract every `${VAR}` that the
component reads, including the `:=` and `:-` defaults. Then compare each one with what the app
actually is.

```bash
grep -rn '\${' kube/clusters/artemis/components/<name>/
```

| Component       | Precondition to verify                                                                                                                                                                                                                                                                                                                                                                                                         | How                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kopiur/backup` | The mover's uid/gid matches the on-disk ownership of the app's data. `KOPIUR_PUID`/`KOPIUR_PGID` both default to `1000` (`components/kopiur/backup/snapshotpolicy.yaml`, `restore.yaml`).                                                                                                                                                                                                                                      | Compare to the pod's `runAsUser`/`fsGroup`. If they differ and `ks.yaml` sets no `KOPIUR_PUID`, that is a finding. The "Mover uid" bullet in `kopiur.md` § kopiur says `fsGroup` misleads, so make sure of the real ownership with `mise run //kube/clusters/artemis:browse-pvc <ns> <claim>` and `ls -ln` before you call it broken. Also make sure that the identity in `restore.yaml` mirrors the identity of the SnapshotPolicy. A mismatch shows only during a restore, which is the worst time to find it. |
| `zeroscaler`    | `${CONTROLLER}` defaults to `Deployment`. A StatefulSet app without it targets a resource that does not exist. Also, the metric is not what the name suggests. Check how many series the metric of the HPA actually has.                                                                                                                                                                                                       | Run `kubectl get hpa -n <ns> <app>`. If `TARGETS` reads `<unknown>/1`, the metric does not resolve. If `REFERENCE` names a kind that the app does not use, the substitution is wrong. Then query the metric itself. If every HPA in the cluster reads the _same single series_, this is a shared-fate gate, not per-app autoscaling.                                                                                                                                                                             |
| `postgres/app`  | The app uses the DSN key that matches its driver: `url` (libpq), `url_node` (postgres-js), or `url_prisma` (Prisma). `pg_hba` is `scram-sha-256` (`postgres-dragonfly.md`).                                                                                                                                                                                                                                                    | Step 2.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `tinyauth`      | The three ACL keys exist in `security/tinyauth/app/helmrelease.yaml`: `TINYAUTH_APPS_<NAME>_OAUTH_WHITELIST` (must be `"/.*/"`), `_OAUTH_GROUPS`, and `_LDAP_GROUPS`. Under `TINYAUTH_AUTH_ACLS_POLICY: deny` an app with none is locked out entirely. The app's namespace must also appear in `security/tinyauth/app/resourceset.yaml`'s `spec.inputs`, or the `SecurityPolicy` sits `Accepted=False` with `RefNotPermitted`. | `grep TINYAUTH_APPS_<NAME> kube/clusters/artemis/apps/security/tinyauth/app/helmrelease.yaml`, `sed -n '/inputs:/,/resources:/p' kube/clusters/artemis/apps/security/tinyauth/app/resourceset.yaml`, `kubectl get referencegrant -n security`. Then Step 3.                                                                                                                                                                                                                                                      |
| `envoy-oidc`    | A `PocketIDOIDCClient` exists for the app with `callbackUrls` ending `/oauth2/callback` and `secret.keys.clientSecret: client-secret`. Also, `dependsOn` includes `pocket-id-operator` (`security`). The component's `SecurityPolicy` `<app>-oidc` targets the app's real HTTPRoute (`${HTTP_ROUTE_TARGET:=${APP}}`), and `${OIDC_HOST}` matches the route's hostname.                                                         | `kubectl get securitypolicy -n <ns> <app>-oidc -o yaml`, `kubectl get pocketidoidcclient -n <ns> <app>`, `kubectl get httproute -n <ns>`. Then Step 3.                                                                                                                                                                                                                                                                                                                                                           |

Then ask the inverse: is a component obviously needed and absent? Examples are a PVC with no
`kopiur/backup` (advisory A2) and a publicly routed app with no gate (A10). Also ask the reverse:
is a component present that the app must not have? An app that holds a long-lived connection (an
SSE subscription, a websocket, a queue consumer) must not carry `zeroscaler`. An app that takes
minutes to become healthy pays that cost on every scale-up.

A component that renders is not a component that works. Kustomize accepts a patch target that
matches nothing. So a component can apply cleanly, leave Flux green, and reach none of the
resources of the app. Make sure that the objects it must produce exist and are wired to the app.

---

## Step 2 — Database: can this app actually authenticate?

If the app has no database at all, skip this step and say why it does not need one.

Know the current wiring before you judge an app against it. The source of truth is the component
under `kube/clusters/artemis/components/postgres/` and `postgres-dragonfly.md` § Onboarding an app
onto shared Postgres. Read both. This is what they set today:

- Auth is a password over TLS. The live `pg_hba` is `hostssl all all all scram-sha-256`. There are
  no client certificates, no pooler and no pgbouncer sidecars
  (`postgres-dragonfly.md` § There are no pgbouncer sidecars). Do not recommend a sidecar.
- `components/postgres/app` creates a `<app>-postgres` Secret in the namespace of the app, from the
  1Password item `postgres-artemis`. The Secret holds three DSN keys (`url`, `url_node`,
  `url_prisma`) and the discrete fields `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DATABASE`,
  `POSTGRES_USERNAME` and `POSTGRES_PASSWORD`. Every DSN points at
  `postgres-rw.database.svc:5432` with `sslmode=verify-full`.
- It also creates a `<app>-postgres` ConfigMap with `PGSSLMODE: verify-full` and `PGSSLROOTCERT`.
  The app connects with the Secret, not the ConfigMap.
- It emits a `ResourceSetInputProvider` named `<app>-postgres`. The `postgres-tenants` ResourceSet
  of the namespace (`components/postgres/tenants`) turns it into a `DatabaseRole`, a `Database` and
  a role Secret. All three are in the `database` namespace, not in the namespace of the app.
- Its patch (`components/postgres/app/patch`) targets a `HelmRelease` only. It adds three ksgate
  scheduling gates and mounts the `postgres-server-ca` Secret at
  `/var/run/secrets/postgres-server-ca`. It skips a HelmRelease that carries the annotation
  `postgres.dcunha.io/skip-patch`.

Then audit the app:

1. Does it support Postgres, and how? Cite the env var names that it exposes. Read them from
   upstream source at the running tag or from the image itself. Never read them from a doc, a
   brief, or a previous audit. Briefs get this wrong routinely, in both directions.
2. Does it use the DSN key that fits its driver? Pick by driver, from the table in
   `postgres-dragonfly.md` § Onboarding an app onto shared Postgres, step 3:
    - `url`: libpq, pgx and node-postgres.
    - `url_node`: postgres-js. The CA comes through `NODE_EXTRA_CA_CERTS`.
    - `url_prisma`: Prisma. Its `sslcert` parameter means the root certificate.
    - The discrete `POSTGRES_*` fields: an app that takes host, port, user and password
      separately.

    A wrong key is not a soft failure. If postgres-js gets the `url` key, it fails with
    `unrecognized configuration parameter "sslrootcert"` and never connects. If Prisma gets a key
    that it does not understand, it fails open and connects without a check of the server. The
    `check-postgres` task tests the `url` key only, so it cannot prove that the app picked the
    right key.

3. Does the pod mount the server CA? `verify-full` needs `postgres-server-ca` at
   `/var/run/secrets/postgres-server-ca`. The patch adds the mount to a HelmRelease. An app that is
   a custom resource, or a HelmRelease with `postgres.dcunha.io/skip-patch`, must declare its own
   mount (`postgres-dragonfly.md` § CR-based apps get the Database CR, but not the pod patch). If
   the mount is missing, nothing reports an error.
4. Check the connection budget before you recommend any onboarding. There is no pooler, so every
   client connection is a server backend. `max_connections` on the shared cluster is a hard
   ceiling that the manifest of no single app reveals. Query
   `SELECT * FROM pg_settings WHERE name = 'max_connections'` and the 14-day peak of
   `cnpg_backends_total`. An app that fits alone can fail to fit in total.
5. Compare declared extensions with the live database. Suppose that a `Database` CR has
   `spec.extensions: []` while the live database has hand-created extensions. A rebuild from git
   then silently recreates the database without them, and every index or query that depends on
   one fails. Compare `\dx` in `psql` with `spec.extensions` in the tree.
6. If the app is on SQLite and stays there, say so explicitly and give the reason. Silence reads
   as an oversight. Single-writer, low-concurrency, and no operational pain is a complete reason
   (`cluster-conventions.md` § Deployment Philosophy). So is "upstream has no Postgres support".
   Make sure of that from source. Do not assume it.
7. If you propose a migration, state all four of these: whether an import path exists and whether
   you ran its `--help` to confirm it, the procedure, the rollback path, and what happens to the
   old PVC (`postgres-dragonfly.md` § Retiring an app's own Postgres leaves its PVC behind). Some
   apps ship a first-class migrator. Others initialize an empty schema and silently leave the
   library, history and settings behind. Never propose deleting a PVC as a migration step. It is
   the last step, after the new path is proven, and it is always RISKY.
8. Cache: if the app uses Dragonfly, compare the index with the allocation table
   (`postgres-dragonfly.md` § Onboarding an app onto shared Dragonfly) and with the live keyspace.
   The manifest can lie, but the keyspace cannot:
   `kubectl -n database exec dragonfly-0 -c dragonfly -- redis-cli INFO keyspace`.
   An app with no index configured silently lands on `0`, the forgot-to-configure tripwire.

Make sure that the wiring resolved, and that the app really uses it. The first command lists the
key names of the Secret only: `url`, `url_node`, `url_prisma`, `POSTGRES_*`. Never print the
values. The `Database` and `DatabaseRole` live in `database`, so read them there.

```bash
kubectl get secret -n <ns> <app>-postgres -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
kubectl get configmap -n <ns> <app>-postgres -o jsonpath='{.data}'
kubectl get database.postgresql.cnpg.io,databaserole.postgresql.cnpg.io -n database <app>
kubectl get pod -n <ns> -l app.kubernetes.io/name=<app> -o jsonpath='{range .items[*]}{.metadata.name}{"  ca="}{.spec.volumes[?(@.name=="postgres-server-ca")].secret.secretName}{"\n"}{end}'
kubectl get pod -n <ns> -l app.kubernetes.io/name=<app> -o jsonpath='{.items[*].status.conditions[?(@.type=="PodScheduled")].reason}'
```

The `Database` and the `DatabaseRole` must both show `APPLIED` `true`. An empty `ca=` means that
the pod has no server CA mount.

`SchedulingGated` is expected while the ksgate gates wait on Postgres. It is not a stuck pod.
`pg_stat_activity` and `pg_stat_ssl` on the primary prove that a connection exists and that it
uses TLS (`ssl` is `t`). They show that the app did not quietly fall back to a local file.

---

## Step 3 — Auth: what does the gate let through, and what does it break?

Find which mechanism the app is on (`identity-stack.md` § Gating apps): native
`PocketIDOIDCClient`, `components/envoy-oidc`, `components/tinyauth`, or
unauthenticated-behind-the-internal-gateway. All are legitimate. State which one applies, and
whether it fits the exposure of the app. Also note the internal auth of the app. Suppose that an
app runs with authentication disabled, or with a subnet allow-list that covers the whole LAN
rather than the pod CIDR. Then it is open to anything that can reach its route.

If a tinyauth gate exists or is proposed, list the machine-to-machine callers of the app before
anything else. ext_authz intercepts every request on the route. The rule:

- A caller that uses `<app>.<ns>.svc.cluster.local` bypasses the gateway entirely and is
  unaffected.
- A caller that uses the public hostname is broken unless you exempt it with
  `TINYAUTH_APPS_<NAME>_PATH_ALLOW`.

Find the callers. Do not reason about them from memory:

```bash
grep -rn '<app>\.dcunha\.io' kube/clusters/artemis/ .agents/
grep -rn '<app>\.<ns>\.svc' kube/clusters/artemis/
```

Then look where grep cannot reach, because the highest-risk callers are not in the tree:

- The database rows or PVC configuration of another app. An integration that you configure
  through a web UI stores its target URL in the database of that app. That stored URL is often the
  public hostname while the manifest looks clean. Query it.
- MCP servers (`cortex-mcp.md`, `memory-config.md`). A tier that dials a public hostname breaks
  the moment the gate lands.
- Webhooks that point at the app from outside, and API tokens that scripts use.
- Native, mobile and TV clients, which cannot complete a browser OIDC flow at all. For an app
  with those clients, the honest recommendation is often "do not gate this one".
- The probes of the app hit the Service, not the route, so ext_authz does not affect them.
  Still, make sure that the ping endpoint is unauthenticated on the side of the app too.

Report each caller and which side of the line it falls on.

Group-name trap: tinyauth env uses underscores (`app_admin`, `app_ops`). A
`PocketIDOIDCClient.allowedUserGroups[].name` uses the CR name with hyphens (`app-admin`). If you
swap them, it fails silently.

---

## Step 4 — Resources: declared vs observed

Existence is not the check. Compare what the manifest declares to what the pod actually uses.

```bash
kubectl top pod -n <ns> --no-headers | grep <app>
kubectl get pod -n <ns> -l app.kubernetes.io/name=<app> \
  -o jsonpath='{range .items[*].spec.containers[*]}{.name}{" req="}{.resources.requests}{" lim="}{.resources.limits}{"\n"}{end}'
```

`top` is one instant. Treat it as a floor, not a ceiling, and never size from it alone. Get the
shape over time from VictoriaMetrics through the Grafana MCP tools:
`max_over_time(container_memory_working_set_bytes[14d])` and a CPU quantile over the same window.
Check every container in the pod, sidecars included. The container that is about to OOM is rarely
the main one. For a `zeroscaler` app, the sample is meaningful only while
the app is awake.

Report these cases, worst first:

- Peak near the limit (for example, above ~85% of `limits.memory` over 14 days). This finding
  matters most, and an instant `top` hides it completely. Read `lastState.terminated` and the
  namespace events for `OOMKilling` to see whether it already fired.
- Request far below observed: the scheduler packs on a false number, the pod is a noisy
  neighbour, and the pod is first to be evicted under pressure.
- Request far above observed: the pod reserves schedulable capacity that it never uses.
- Limit far above observed (an order of magnitude or more): the limit does not do its job. A
  memory limit exists to bound a leak. A limit twenty times above the working set fires only after
  the node is already in trouble. Say what a defensible ceiling is and why.
- Limit absent, or a `BestEffort` pod: a limit is required (H20), and doubly so for anything
  shared.
- A limit that is deliberately generous (a transcoder, an unpacker, a browser-based solver) is
  correct, and you must say so. Do not flag headroom that has a named reason.
- Peak that varies with the node: an app whose worker count derives from `os.cpu_count()` is not
  cgroup-aware, so its memory ceiling changes with the node where the pod lands. Recommend that
  the workers are pinned, instead of a chase after the limit.

Never propose a number without the observation behind it.

---

## Step 5 — Storage and backup reality

- Does the PVC exist, and is it `Bound`? Is its size sane against actual use
  (`kubelet_volume_stats_used_bytes`, or
  `mise run //kube/clusters/artemis:browse-pvc <ns> <claim>`)? Report both the nearly full and the
  wildly oversized.
- Is anything important on an `emptyDir`? A database or a state directory on an emptyDir is
  silently wiped on every restart. This looks completely normal in a manifest.
- Is there a kopiur `SnapshotPolicy`, and did it actually produce a recent snapshot? Read
  `SnapshotPolicy.status.lastSuccessfulSnapshot`, or `kopiur status -n <ns>`. A wired component
  that never ran is not a backup.
- Does the backup back up junk? Stale in-PVC dumps and `.backup` files get uploaded again on
  every run. Name them.
- Are there orphaned PVCs left by an earlier migration, that is, a claim with no consumer?
  `reclaimPolicy: Delete` fires only on PVC deletion, so the cluster holds an unreferenced claim
  forever, replicated (`storage.md` § Orphaned PVCs).
- NFS media mounts: the server, the path and the uid that every write lands as are in
  `media-stack.md` § TrueNAS NFS. Note an app that runs as a different uid on NFS. Also look for
  data on NFS that must not be there. Workloads with heavy small-file IOPS (unpacking, databases,
  indexes) belong on block storage. A live configuration can violate a documented rule about that,
  because no manifest shows it.

---

## Step 6 — Route, exposure, and observability

- The gateway must match the exposure: LAN-only on `internal-gateway`, public (either domain) on
  `edge-gateway`, all in namespace `network`. A route on `external-gateway` is a finding (legacy,
  no upstream). On `edge-gateway`, `*.dcunha.io` must not pin `sectionName: https`. See
  `towonel-agent.md` § Which gateway a route uses.
- The live HTTPRoute is authoritative. An app can have more than one, with different parents,
  different path prefixes and header filters. Read `kubectl get httproute`. Do not infer from
  `values.route`.
- Public exposure without a gate is advisory A10. Attach the inverse question from Step 3.
- The live Service port is authoritative. Ports are not uniform in every namespace
  (`media-stack.md` § Internal Cluster DNS). Anything that wires to this app by port must match the
  Service, not the upstream default.
- Does the app expose `/metrics` with no scrape? There is no kube-prometheus-stack here. The stack
  is VictoriaMetrics à-la-carte, and the VM operator converts `ServiceMonitor` (advisory A18,
  `observability.md`).
- Does the app do anything at all? An app with no traffic, an empty log since its last start, and
  a flat network profile over 14 days can already be orphaned by a replacement. Raise that
  finding. Dead weight costs a PVC, a backup slot and a maintenance surface.

---

## Step 7 — Doc drift

Every audit ends with a check of the claims that the repo makes about this app. This is how the
docs stay true. Nothing else in the repo does it.

For each reference that names the app, verify its specific assertions against what Steps 0-6
found: ports, gateway, components, database, auth mechanism, resource claims, membership lists,
and any `verified against the live cluster YYYY-MM-DD` header.

```bash
grep -rn '<app>' AGENTS.md README.md .agents/
```

Include the stated rules of the repo, not only its descriptions. Suppose that the live
configuration of the app violates a documented critical rule. That is doc drift in the more
dangerous direction: the doc is right and the cluster is wrong.

Report each mismatch as `file:line`, the quoted claim, and what is actually true. Do not fix
them, because you are read-only. List them for the caller.

---

## Report

```markdown
# Audit: <app> (<namespace>)

## Verdict

OK | needs work | broken, with one line of why.

## Current state

Image/tag, controller kind and replicas, ports (live Service), route + gateway (live HTTPRoute),
components wired, storage and observed usage, auth mechanism, database and its connection path.

## Findings

Numbered, worst first. Each one has these parts:

- What's wrong: one sentence.
- Evidence: `file:line`, or the live object inspected, quoted.
- Severity: broken (it does not work) | risk (it works until it breaks) | drift (it works,
  but this repo does it another way).
- Fix: the concrete YAML that you propose.
- SAFE or RISKY: SAFE is pure config with no data or access consequence. RISKY is anything
  that migrates data, changes auth, or can lock out or empty an app. Be honest. The caller
  sequences on this.

## Deliberate non-changes

Things that look wrong and are correct, with the reason. This section is not optional. An audit that only
lists problems invites a later agent to "fix" a deliberate choice. If a doc records the decision,
cite it.

## Doc drift

`file:line`, the quoted claim, and what is actually true.

## Unverified suspicions

Anything not confirmed, and what you need to confirm it.
```

## Gotchas

- `kubectl rollout restart` does nothing on a zero-scaled app.
- `kubectl top` on a pod that just woke up reads low, and one sample is not a working set. Do not
  size resources from a cold instant.

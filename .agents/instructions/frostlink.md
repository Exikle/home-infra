---
paths:
    - "kube/clusters/frostlink/apps/**"
    - "kube/clusters/frostlink/components/**"
---

# Frostlink — differences from Artemis

Frostlink is a single-node Talos cluster under `kube/clusters/frostlink/`. `cluster-conventions.md`
and `yaml-conventions.md` also load here and hold the shared rules. Rules in this file win over
any rule they label (Artemis). Tasks are `mise run //kube/clusters/frostlink:<task>`.

## Apps

- Every app is `ks.yaml` plus `app/` with `kustomization.yaml`, `ocirepository.yaml` and
  `helmrelease.yaml`. Routes and ExternalSecrets are inline in the HelmRelease values.
- Standalone `externalsecret.yaml` is also kept in a directory with no HelmRelease
  (`clusterissuer`, `postgres`, `kopiur`, `certificates`). Set `target.name` explicitly. With one
  entry, the object is named after the release, so `forceRename` is only for keeping an old name.
- Never set `TZ`. k8tz handles it.

## Single node

- Workloads schedule on the control plane (`taints: $patch: delete` in
  `kube/clusters/frostlink/talos/patches/controlplane.yaml`). No `nodeSelector` is needed.
- No Rook-Ceph. Node work: `.agents/references/oci-talos.md`. Rebuild: `.agents/references/oci-rebuild.md`.

## Storage

- Default class: `openebs-zfs` (ZFS-backed). `miroir` does not exist here. See
  `.agents/references/openebs-zfs.md`, which also covers backups (Kopiur to Cloudflare R2).

## Database and cache

One shared CNPG `Cluster/postgres` with `Pooler/pooler-rw`, and one shared `Dragonfly`, both in
the `database` namespace. No app runs its own Postgres, Redis or Valkey. Full detail:
`.agents/references/database.md`.

- Connect only through `pooler-rw.database.svc:5432`. Never to the `Cluster` directly.
- Onboard an app with the `kube/clusters/frostlink/components/postgres/cert` component in
  its `ks.yaml`. It makes the `Database` CR, a client `Certificate` and a `ConfigMap` with the
  mTLS DSN. Auth is by certificate, so there is no password. Apps read the DSN from the ConfigMap.
  `ksgate` holds the app pod until the `Database` CR is Ready.
- Also add the app's role (`name: <app>`, `login: true`, `disablePassword: true`) to
  `spec.managed.roles` in `kube/clusters/frostlink/apps/database/postgres/cluster/cluster.yaml`.
  Without it you get `role "<app>" does not exist (SQLSTATE 42704)`.
- Client keys use PKCS8 through the CSI path. History and reissue traps: `database.md`
  § Client certificates and § CNPG PKI gotchas.

## Ingress

- One gateway: `external-gateway` in the `network` namespace. There is no `internal-gateway` and
  no `edge-gateway`. Publishing a service: `.agents/references/towonel.md`. Network detail:
  `.agents/references/oci-networking.md`.
- There is no Cloudflare tunnel.

## Common mistakes

| Pattern       | Correct                          | Wrong                                       |
| ------------- | -------------------------------- | ------------------------------------------- |
| Gateway       | `external-gateway` only          | `internal-gateway`, `edge-gateway`          |
| Storage class | `openebs-zfs`                    | `miroir`, `local-path`, `ceph-block`        |
| App database  | shared `postgres/cert` component | sidecar postgres, SQLite, app-specific CNPG |
| App cache     | shared Dragonfly (`database` ns) | sidecar Redis/Valkey                        |

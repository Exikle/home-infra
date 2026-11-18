---
paths:
    - "kube/clusters/frostlink/apps/**"
    - "kube/clusters/frostlink/components/**"
---

# Frostlink — differences from Artemis

Frostlink is a single-node Talos cluster under `kube/clusters/frostlink/`.
`cluster-conventions.md` and `yaml-conventions.md` also load here and hold the shared rules. The
rules in this file win over any rule that those files label (Artemis). Tasks are
`mise run //kube/clusters/frostlink:<task>`.

## Apps

- Every app is `ks.yaml` plus `app/`. The `app/` folder holds `kustomization.yaml`,
  `ocirepository.yaml` and `helmrelease.yaml`. Routes and ExternalSecrets are inline in the
  HelmRelease values.
- A directory with no HelmRelease also keeps a standalone `externalsecret.yaml`. To list every
  standalone one, run `find kube/clusters/frostlink -name externalsecret.yaml`. Set `target.name`
  explicitly. With one entry, the object gets the name of the release. Use `forceRename` only to
  keep an old name.

## Single node

- Workloads schedule on the control plane (`taints: $patch: delete` in
  `kube/clusters/frostlink/talos/patches/controlplane.yaml`). No `nodeSelector` is needed.
- Node work: `.agents/references/oci-talos.md`. Rebuild: `.agents/references/oci-rebuild.md`.

## Storage

- The default class is `openebs-zfs` (backed by ZFS). `miroir` does not exist here. Read
  `.agents/references/openebs-zfs.md`. It also covers backups (Kopiur to Cloudflare R2).

## Database and cache

Frostlink has one shared CNPG `Cluster/postgres` with `Pooler/pooler-rw`, and one shared
`Dragonfly`. Both are in the `database` namespace. No app runs its own Postgres, Redis or Valkey.
`.agents/references/database.md` has the full detail and wins over this section.

- Connect only through `pooler-rw.database.svc:5432`. Never connect to the `Cluster` directly.
- To onboard an app, add the `kube/clusters/frostlink/components/postgres/csi` component to its
  `ks.yaml`. If the Postgres driver of the app is lib/pq, use `components/postgres/cert` instead.
  `database.md` § Client certificates gives the reason and the command that reads the driver out
  of the binary.
- Both components make the `Database` CR, the `DatabaseRole` CR and a `ConfigMap` with the mTLS
  DSN. Auth is by client certificate, so there is no password. The app reads the DSN from the
  ConfigMap. `ksgate` holds the app pod until the `Database` CR is applied.
- The `DatabaseRole` of the component makes the role of the app. Do not add the role to
  `spec.managed.roles` in `kube/clusters/frostlink/apps/database/postgres/cluster/cluster.yaml`.
  That list holds only `pooler-rw`.
- If the app gets `role "<app>" does not exist (SQLSTATE 42704)`, the `DatabaseRole` did not
  reconcile. Read its state with `kubectl get databaseroles -n database --context frostlink`.
- The CSI component uses PKCS8 client keys. History and reissue traps: `database.md`
  § Client certificates and § CNPG PKI gotchas.

## Ingress

- There is one gateway: `external-gateway` in the `network` namespace. There is no
  `internal-gateway` and no `edge-gateway`. To publish a service, attach its route to
  `external-gateway`. external-dns then makes its DNS record (`oci-networking.md` § Gateway and
  § DNS).
- Network detail: `.agents/references/oci-networking.md`.

## Common mistakes

| Pattern              | Correct                          | Wrong                                |
| -------------------- | -------------------------------- | ------------------------------------ |
| Gateway              | `external-gateway` only          | `internal-gateway`, `edge-gateway`   |
| Storage class        | `openebs-zfs`                    | `miroir`, `local-path`, `ceph-block` |
| App needing Postgres | shared `postgres/csi` component  | sidecar postgres, app-specific CNPG  |
| App cache            | shared Dragonfly (`database` ns) | sidecar Redis/Valkey                 |

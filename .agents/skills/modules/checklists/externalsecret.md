# Checklist: ExternalSecret

Run this if `helmrelease.yaml` has `values.externalSecrets`, or a standalone `externalsecret.yaml`
is present (only allowed for the exceptions in `cluster-conventions.md` § Secrets).

Mark each item **PASS**, **FAIL**, or **N/A**.

| #   | Check                                                                                | Result |
| --- | ------------------------------------------------------------------------------------ | ------ |
| E1  | app-template app → defined inline under `values.externalSecrets`, no standalone file |        |
| E2  | `secretStoreRef.kind: ClusterSecretStore`, `name: onepassword-connect`               |        |
| E3  | `target.name` set explicitly                                                         |        |
| E4  | `dataFrom[].extract.key` matches the exact 1Password item name                       |        |
| E5  | Template field names use `{{ .FIELD_NAME }}` syntax                                  |        |
| E6  | Standalone file only: `apiVersion: external-secrets.io/v1` (not `v1beta1`)           |        |

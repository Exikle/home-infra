# Module: ExternalSecret Template

Only add this if the app needs secrets from 1Password. For app-template apps it goes **inline in
`helmrelease.yaml`**, not in a separate file:

```yaml
spec:
    values:
        externalSecrets:
            app:
                dataFrom:
                    - extract:
                          key: <1password-item-name>
                secretStoreRef:
                    kind: ClusterSecretStore
                    name: onepassword-connect
                target:
                    name: <app>
                    template:
                        data:
                            SOME_KEY: "{{ .FIELD_NAME }}"
```

Reference it from a container with `envFrom: [{externalSecretRef: {identifier: app}}]`, or by the
Secret name in `secretKeyRef`.

## Notes

- `secretStoreRef.name` must be `onepassword-connect` (not `onepassword`, not `1password-connect`).
- `dataFrom.extract.key` is the exact name of the 1Password item.
- Template field names must **exactly** match 1Password field names — a mismatch returns an empty secret with no error.
- Set `target.name` so the Secret is predictably named. With one entry the ExternalSecret itself is named after the release; use `forceRename` only to keep a pre-existing name.
- The chart sets `target.deletionPolicy: Delete` by default.
- Add `onepassword-connect` to `dependsOn` in `ks.yaml` whenever an ExternalSecret is present.
- A standalone `externalsecret.yaml` (`apiVersion: external-secrets.io/v1`, no `namespace:`) is only for the exceptions in `cluster-conventions.md` § Secrets — a non-app-template chart, no HelmRelease, or a Secret read by `postBuild.substituteFrom`.

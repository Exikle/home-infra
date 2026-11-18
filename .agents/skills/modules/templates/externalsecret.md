# Module: ExternalSecret Template

Add this only if the app needs secrets from 1Password. For app-template apps, put it inline in
`helmrelease.yaml`, not in a separate file.

Frostlink house style: name the entry `app` (not `env`), and set `target.name` and `forceRename`
to the Secret name. With one entry, the chart already uses the name of the release, so this
changes no behaviour. Reference the Secret from a container with
`envFrom: [{secretRef: {name: <app>}}]`, or by name in `secretKeyRef`.

```yaml
spec:
    values:
        externalSecrets:
            env:
                dataFrom:
                    - extract:
                          key: <1password-item-name>
                secretStoreRef:
                    kind: ClusterSecretStore
                    name: onepassword-connect
                target:
                    template:
                        data:
                            SOME_KEY: "{{ .FIELD_NAME }}"
```

Reference it from a container with `envFrom: [{externalSecretRef: {identifier: env}}]`.

## Notes

The store name, the API version and the field-name rule are in `cluster-conventions.md`
§ Secrets, which wins. These notes are only about this template:

- `dataFrom.extract.key` is the exact name of the 1Password item.
- Naming: with one entry, the ExternalSecret and its Secret take the name of the release. With
  several entries, they are named `<release>-<id>`. `target.name` overrides the Secret name.
  `forceRename` overrides the ExternalSecret name.
- The chart sets `target.deletionPolicy: Delete` by default.
- Add `onepassword-connect` to `dependsOn` in `ks.yaml` whenever an ExternalSecret is present.
- A standalone `externalsecret.yaml` (`apiVersion: external-secrets.io/v1`, no `namespace:`,
  `spec` alphabetical: `dataFrom → refreshInterval → secretStoreRef → target`) is only for the
  exceptions in `cluster-conventions.md` § Secrets.

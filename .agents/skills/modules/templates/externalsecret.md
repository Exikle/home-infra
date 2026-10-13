# Module: ExternalSecret Template

Only when the app needs 1Password secrets. For app-template apps it goes inline in
`helmrelease.yaml`, not a separate file:

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

Reference it from a container with `envFrom: [{secretRef: {name: <app>}}]` or by Secret name in
`secretKeyRef`. Add `onepassword-connect` (namespace `external-secrets`) to the `ks.yaml`
`dependsOn`. Field names must match the 1Password item exactly. Rules and the standalone-file
exceptions: `cluster-conventions.md` § Secrets.

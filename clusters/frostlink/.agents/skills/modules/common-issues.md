# Module: Common Issues

| Symptom                                                           | Cause                                              | Fix                                                                                   |
| ----------------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Permission denied on startup                                      | Image UID does not match `runAsUser: 1000`         | Temporarily set `runAsNonRoot: false` to find the UID, then align the securityContext |
| Crash on write to `/tmp`                                          | `readOnlyRootFilesystem: true` without an emptyDir | Add a `tmp` emptyDir with `advancedMounts` and `subPath: tmp`, even for one path      |
| Pod stuck in `Init`                                               | ExternalSecret not synced                          | Below                                                                                 |
| HelmRelease stuck, OCIRepository or Kustomization not reconciling | See the `fix-flux` skill                           |                                                                                       |

## ExternalSecret not syncing

- 1Password field names must match exactly (case-sensitive); a mismatch gives an empty secret with no error.
- `just kube sync es` forces a refresh; `kubectl describe externalsecret <app> -n <namespace> --context frostlink` shows sync status.

## OCIRepository not resolving

Check `url: oci://ghcr.io/bjw-s-labs/helm/app-template` (`-labs`) and `apiVersion: source.toolkit.fluxcd.io/v1`.

## dependsOn and KOPIUR_CAPACITY

Cross-namespace `dependsOn` needs an explicit `namespace:` (`flux-patterns.md` § flate `dependsOn`
Namespace). `KOPIUR_CAPACITY` belongs in `ks.yaml` `postBuild.substitute`, not in `persistence`.

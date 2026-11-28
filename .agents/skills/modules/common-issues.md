# Module: Common Issues

On Frostlink, use `mise run //kube/clusters/frostlink:<task>` for the tasks below. Also add
`--context frostlink` to every `kubectl` and `flux` command. For a stuck HelmRelease,
OCIRepository or Kustomization, use the `fix-flux` skill.

## Runtime / pod failures

| Symptom                                                        | Cause                                           | Fix                                                                                                         |
| -------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Permission denied on startup                                   | Image UID does not match `runAsUser: 1000`      | Set `runAsNonRoot: false` for a short time to find the UID that the image needs. Then align securityContext |
| Crash on write to `/tmp`                                       | `readOnlyRootFilesystem: true` without emptyDir | Add a `tmp` emptyDir persistence entry (`templates/helmrelease.md`)                                         |
| Pod stuck in `Init`                                            | ExternalSecret not synced                       | Read the ExternalSecret section below                                                                       |
| `OSError: [Errno 16] Device or resource busy` on `os.rename()` | App rewrites a file mounted from a ConfigMap    | Read the ConfigMap mount section below                                                                      |

## Writes to ConfigMap-mounted files fail

ConfigMap files are read-only bind mounts, so a rewrite in place fails. `os.rename()` returns
`OSError: [Errno 16] Device or resource busy`, not a permissions error. So the error sends you to
securityContext instead of to the mount.

Copy the file out before the app starts:

1. Mount the ConfigMap at a staging path.
2. Add an initContainer that copies the file into an `emptyDir`.
3. Point the app at the `emptyDir` copy.

## ExternalSecret not syncing

- A template field name that does not match the 1Password field name gives an empty secret with
  no error (`cluster-conventions.md` § Secrets).
- To force a refresh, run `mise run //kube/clusters/<cluster>:sync-flux es <app>`. Name the app,
  or the task refreshes every ExternalSecret.
- To read the sync status, run `kubectl describe externalsecret <app> -n <namespace>`.

## HelmRelease stuck / not progressing

1. Retry the release: `mise run //kube/clusters/<cluster>:unstick-hr <namespace> <app>`. The task
   forces a one-off install or upgrade, and it resets the failure count.
2. If the release is still stuck, ask the user. Then run
   `mise run --yes //kube/clusters/<cluster>:reset-hr <namespace> <app>`. The task deletes the Helm
   release history and reinstalls. You lose the rollback to earlier revisions.

Both tasks leave the HelmRelease resumed. `fix-flux` has the diagnosis steps.

## Probe endpoint reference

Read the docs of the app. Do not assume `/`. A wrong probe path causes a crash loop, not a soft
failure. `cluster-conventions.md` § Common Mistakes — Quick Reference has the arr-app row.

## KOPIUR_CAPACITY in wrong place

Frostlink only. `KOPIUR_CAPACITY` must be in `ks.yaml` under `postBuild.substitute`, not in the
`persistence` spec of the app. The kopiur component reads it as `${KOPIUR_CAPACITY:=5Gi}`. On
Artemis the size is in the claim template of the StatefulSet (`.agents/references/kopiur.md`
§ Backing up an app).

# Module: Test and Commit

`main` is production, so nothing is committed before it has run live. The sequence and its reasons
are `.agents/instructions/commit-style.md` § Exikle workflow — always test before committing;
suspend mechanics are `flux-patterns.md` § Suspend before a test-apply. This module is the
app-specific commands.

1. Look up the Kustomization name (it is `metadata.name` in `ks.yaml`, not always `<app>`):

    ```bash
    grep "^  name:" kubernetes/apps/<namespace>/<app>/ks.yaml
    ```

2. Render offline (`flux-validate` skill has the full suite):

    ```bash
    just kube render-local-ks <namespace> <ks-name>
    ```

3. Suspend the root and the target, then apply (three calls):

    ```bash
    just kube suspend-ks flux-system flux-system
    just kube suspend-ks <namespace> <ks-name>
    just kube apply-ks <namespace> <ks-name>
    ```

4. Check it landed:

    ```bash
    kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app> --context frostlink
    kubectl describe helmrelease <app> -n <namespace> --context frostlink
    ```

5. **Wait for explicit user confirmation.** Never commit before it.
6. Commit as `commit-style.md` says (specific files, `git diff --staged`, one-line subject). The
   artifact only rebuilds on a push to `main`, and the user commits and pushes their own work
   straight to `main` (no PR). So after confirmation, hand the branch back and ask the user to land
   it on `main`; do not leave the root and target suspended, and do not push yourself.
7. Once the artifact has rebuilt (`just kube sync ocirepo` until the `flux-system` digest moves),
   resume — root first, then the target (`commit-style.md` step 5). If the user abandons the change,
   resume both straight away.

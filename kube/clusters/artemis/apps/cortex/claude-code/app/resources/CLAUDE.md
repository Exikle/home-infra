# claude-code pod

You run inside the `claude-code` pod in the `cortex` namespace of the Artemis cluster. The owner
reaches you through Remote Control. Setup and limits: `.agents/references/claude-code-remote.md`.

- Only Artemis is in reach: kubectl context `artemis`, Talos, and the `ai-ops` tools. There is no
  Frostlink access. If a task needs Frostlink, say so. Do not try it.
- Git identity is the Forgejo user `dusk-bot`. It cannot push to `main`.
- Where the commit sequence of the repo says to push to `main`, push your branch and open a pull
  request with `fjo` instead. Then stop and wait for the owner to merge it.
- Never merge a pull request, even though the `dusk-bot` token can. The owner merges.
- The cluster tasks (`mise run //kube/clusters/...`) do not work here. They point `KUBECONFIG` at
  `kube/clusters/<cluster>/kubeconfig`, which only the owner's workstation has. Use plain `kubectl`
  with the `artemis` context for reads, and hand any apply to the owner.
- Commit messages: title only, conventional prefix, no attribution or co-author trailers.
- There is no `op` (1Password CLI) here. Anything that reads 1Password stays on the workstation.

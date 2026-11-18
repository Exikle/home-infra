# claude-code — Remote Control in the cluster

`kube/clusters/artemis/apps/cortex/claude-code` runs `claude remote-control` in a pod. With it, you
can work on the cluster from claude.ai/code or the Claude app, without the workstation. Each
session that you start from there gets its own git worktree. The worktree is of a clone of this
repo on the PVC of the pod.

## Access, and what guards it

| Reach      | How                                                                                                                                                |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kubernetes | ServiceAccount bound to `cluster-admin`, as a kubeconfig with context `artemis`                                                                    |
| Talos      | `talos.dev` ServiceAccount `claude-code-talos` (`os:admin`). Talos writes and rotates the Secret, which is mounted at `/var/run/secrets/talos.dev` |
| Forgejo    | `DUSK_BOT_CLUSTER_TOKEN` from the `forgejo` item. git and `fjo` act as dusk-bot                                                                    |
| memini     | In-cluster service, with the same namespace configuration as the workstation                                                                       |

The Talos access needs `cortex` in `allowedKubernetesNamespaces` of the `KubeTalosAPIAccessConfig`
in `kube/clusters/artemis/talos/controlplane.yaml.j2`. That change applies without a reboot.

RBAC does not limit the access. These guards limit it:

- Permission mode `default`. Every tool call outside the `.claude/settings.json` allowlist of the
  repo waits for approval in the app.
- `guard-destructive.sh`. It comes with the repo checkout. It blocks the destructive verbs, as it
  does on the workstation.
- Branch protection on `main`. It allows pushes only from Exikle, so the pod lands work as a pull
  request. The `~/.claude/CLAUDE.md` of the pod (from `app/resources/CLAUDE.md`) says so.
- The permission prompt. The pod uses the token of dusk-bot, and dusk-bot is a repo admin. Branch
  protection does not apply to admins. So the token can merge a PR without the
  `Kritika / Review` check. The admin role is kept on purpose. Only the permission prompt stops a
  merge, and the pod never pre-approves a merge.
- No ingress. The NetworkPolicy denies all ingress. Remote Control only dials out.

## Tools

`app/resources/mise.toml` is the global mise configuration of the pod. It has the cluster tools of
the workstation, plus the two MCP servers (`kubernetes-mcp-server`, `flux-operator-mcp`). The
`.mise/config.toml` of the repo adds its pins on top.

The entrypoint puts `mise bin-paths` on `PATH`. It does not activate mise. The reason is that the
mise env of the repo points `KUBECONFIG` and `TALOSCONFIG` at files that exist only on the
workstation.

The agentgateway tiers in the `.mcp.json` of the repo name a `headersHelper` path that exists only
on the workstation. The pod mounts its own `app/resources/ai-headers.mjs` at that same path. This
is how the helper works:

1. It reads the tier keys (`KEY_OPS` / `KEY_GENERAL` from the `agentgateway` item) from files
   under `/var/run/secrets/agentgateway`.
2. It returns `{"x-api-key": …}`.

The helper uses files, not env vars. Claude Code runs the helper without the environment of the
pod, so a helper based on env vars returns no headers. The server then returns a 401. The 401
sends Claude into OAuth discovery, and that fails.

The entrypoint sets `enableAllProjectMcpServers`, so the tiers need no approval prompt.

There is no `op` in the pod. So tasks that need 1Password stay on the workstation.

## The PVC is not backed up

The `claude-code` PVC holds the claude.ai login, the plugins, the tool installs and the clone. It
has no kopiur component, so the login credential never leaves the cluster. If the PVC is lost, you
must do the bootstrap again.

## One-time bootstrap

Remote Control needs a full claude.ai login. It rejects a `claude setup-token` token. It also needs
a one-time interactive answer to "enable Remote Control" and to workspace trust. Until
`~/.remote-control-ready` exists, the pod installs everything and then sleeps.

```bash
kubectl exec -it -n cortex deploy/claude-code -c app --context artemis -- bash
export PATH="$HOME/.local/bin:$PATH"
claude auth login                                # claude.ai account, paste the code back
cd ~/Artemis-Cluster && claude remote-control    # answer y and y, then Ctrl-C
touch ~/.remote-control-ready
exit
kubectl rollout restart -n cortex deploy/claude-code --context artemis
```

The `export PATH` line is required. Without it, the shell reports `claude: command not found`.
`-c app` picks the app container. Without it, kubectl picks one and prints `Defaulted container`.

The server then shows as `artemis` in claude.ai/code. If the login expires, the pod goes into a
restart loop. Follow § Log in again after the login expires. A plain `exec` and `claude auth login`
do not work then.

Remote Control refuses to start if any of these variables is set:

- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
- `DISABLE_GROWTHBOOK`

So none of them belong in the env of the pod.

Remote Control redraws its status once a second. Without a TTY, these redraws flood the log.
`app/resources/log-filter.pl` strips the escape sequences and drops repeated lines.

## Troubleshooting

If the pod is in `Error` or `CrashLoopBackOff` and restarts every few minutes, find the cause
in its log:

1. Read the log of the current container:
   `kubectl logs -n cortex deploy/claude-code --context artemis --tail=40`. The `--previous`
   flag can fail with `unable to retrieve container logs`, so start without it.
2. Read the last lines. `entrypoint.sh` runs the setup steps in order, and the last line names
   the step that stopped.
3. If the last line is `Error: You must be logged in to use Remote Control.`, the claude.ai login
   on the PVC expired or is gone. `claude remote-control` exits, and the pod restarts. Follow
   § Log in again after the login expires.
4. If the log stops at the install of mise or claude, or at the clone of the repo, a download in
   `entrypoint.sh` failed, and the script exits. The tool, hk and plugin steps print a `WARN`
   line on failure and go on, so they do not stop the pod.
5. If the log ends with `claude-code: not bootstrapped`, the pod is not broken. It waits for
   § One-time bootstrap.

## Log in again after the login expires

You run these steps yourself, because they open a shell in the pod. In the restart loop each
container lives only a few seconds, so `kubectl exec -it` cannot attach. A rollout restart does not
help. Make the pod idle first, then log in.

1. Remove the ready marker. Retry until one `exec` lands inside a container that is still up. It
   took 14 tries on 2026-11-17:

    ```bash
    until kubectl exec -n cortex deploy/claude-code -c app --context artemis -- sh -c 'rm -f ~/.remote-control-ready'; do sleep 2; done
    ```

2. Wait for the next start. Without the marker, `entrypoint.sh` stops at `exec sleep infinity` and
   the pod stays up. Make sure that the log ends with `claude-code: not bootstrapped`.
3. Do the steps in § One-time bootstrap: open the shell, run the `export PATH` line, run
   `claude auth login`, run `claude remote-control` and answer any prompt it shows, then
   `touch ~/.remote-control-ready` and the rollout restart.
4. Wait for the old pod to stop. The Deployment uses the `Recreate` strategy, so the new pod starts
   only after the old one is gone. `sleep infinity` runs as PID 1 and ignores SIGTERM, so the old pod
   takes the full 30-second grace period.
5. Make sure that the new pod runs `remote-control --name artemis` with 0 restarts.

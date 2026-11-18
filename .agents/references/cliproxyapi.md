# cliproxyapi: a Claude subscription as an API

`kube/clusters/artemis/apps/cortex/cliproxyapi` runs CLIProxyAPI (upstream:
<https://github.com/router-for-me/CLIProxyAPI>). CLIProxyAPI is a proxy that logs in to a Claude
account with OAuth and serves that account as an Anthropic-compatible API. Here it serves one
Claude login to clients inside the cluster.

## What uses it

kritika is the only client. Its `claude` provider in
`kube/clusters/artemis/apps/kritika/kritika/app/helmrelease.yaml` sends requests to
`http://cliproxyapi.cortex.svc.cluster.local:8317`. kritika gets `CLIPROXYAPI_API_KEY` from the
`cliproxyapi` 1Password item, the same item that cliproxyapi reads.

The Service has no route. No gateway exposes it outside the cluster. The management API and the
control panel are off (`management` in the config template).

## Configuration

The ExternalSecret in `helmrelease.yaml` renders `config.yaml` from the `cliproxyapi` item. The
only field it reads is `CLIPROXYAPI_API_KEY`. That key is the one API key that clients must send.

The OAuth login is not in 1Password. It is a JSON auth file under `/data/.cli-proxy-api` on the
`cliproxyapi` PVC. CLIProxyAPI refreshes the access token in that file by itself. The kopiur
component backs up the PVC, so the auth file is in the kopiur repository too (`kopiur.md`).

To see the running image tag, run
`grep -A1 'eceasy/cli-proxy-api' kube/clusters/artemis/apps/cortex/cliproxyapi/app/helmrelease.yaml`.

## NetworkPolicy

`app/networkpolicy.yaml` controls ingress only. It allows TCP 8317 from two sources:

1. Pods labelled `app.kubernetes.io/name: agentgateway` in the `cortex` namespace.
2. kritika server pods in the `kritika` namespace.

Egress is open, because the pod must reach the Claude API. kritika has the matching egress rule in
`networkPolicy.extraEgress` of its own HelmRelease. If you add a client in another namespace, add
an ingress rule here and an egress rule on the client.

No agentgateway model points at cliproxyapi today (`kubectl get agentgatewaymodels -n cortex`).
The agentgateway rule allows traffic that nothing sends yet.

## Log in again when the login expires

The refresh token can expire or be revoked. Then kritika reviews that use the `claude` provider
fail. The user runs this procedure, because it opens an interactive process in the pod.

1. Start the login in the running pod:

    ```bash
    kubectl exec -it -n cortex deploy/cliproxyapi -- /CLIProxyAPI/CLIProxyAPI --config /etc/cliproxyapi/config.yaml --no-browser --claude-login
    ```

2. Open the URL that the command prints. Sign in with the Claude account.
3. The browser goes to `http://localhost:54545/...` and shows an error. This is expected. Copy the
   full URL from the address bar.
4. When the command asks `Paste the Claude callback URL`, paste the URL and press Enter.
5. Wait for the command to save the auth file and exit.
6. Make sure that the server loaded the file:
   `kubectl logs -n cortex deploy/cliproxyapi --tail=20`. Look for
   `auth file changed (CREATE)` or `(WRITE)` with a `claude-…json` name.

You do not have to restart the pod. The server watches the auth directory and loads a new file
by itself. If you log in with a different account, the old auth file stays in
`/data/.cli-proxy-api`.

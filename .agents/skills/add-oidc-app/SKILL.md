---
name: add-oidc-app
description: Wire an app into Pocket-ID for single sign-on — create the OIDC client, store the secret in 1Password, and configure the app's OIDC settings and redirect URIs. Use for "add SSO to X", "wire X into Pocket-ID", "set up OIDC for X", or "single sign-on for X". Scoped to the Artemis cluster.
compatibility: Requires Pocket-ID reachable at `https://id.dcunha.io` with `pocket-id-operator` running, and the `op` CLI signed in to write the client secret into 1Password.
---

# Skill: Add OIDC App (Pocket-ID)

This skill wires a new app into Pocket-ID for single sign-on. Pocket-ID is at
`https://id.dcunha.io`, in the `security` namespace. An operator (`pocket-id-operator`) manages it.
You declare clients as `PocketIDOIDCClient` CRs. Never create a client by hand in the web UI.

> Read `.agents/references/networking.md` for gateway names and route syntax before you add any
> HTTPRoute. Edit in a worktree. Run `mise run //:wt:new feat/<slug>` first (`AGENTS.md` rule 7).
> If an app cannot do OIDC itself, use `components/envoy-oidc` (Step 2, last section). The
> tinyauth gate is a different mechanism: `.agents/skills/add-tinyauth-app/SKILL.md`.

## Group Structure

| Group       | Access Level                   |
| ----------- | ------------------------------ |
| `app-admin` | Full access to admin-tier apps |
| `app-ops`   | Operational/infra apps         |
| `app-users` | General apps                   |

The table shows the `PocketIDUserGroup` CR names. Pocket-ID syncs the groups from lldap. In lldap
they are `ID-Admin`, `ID-Ops` and `ID-Users`. The Pocket-ID group `name` is `app_admin`, `app_ops`
and `app_users`. That name uses underscores, not the hyphens of the CR name. An app that reads the
`groups` claim sees the underscored name. See `.agents/references/identity-stack.md` for the full
chain from lldap to Pocket-ID.

## Step 1: Create the `PocketIDOIDCClient` CR

Put the CR with the app's own manifests (for example `<app>/app/oidcclient.yaml`), not in a
central folder. Every existing app does this.

Always set `spec.clientID` explicitly. If you leave it to name-fallback matching, the operator can
mint a random UUID client ID on a later reconcile. This caused a real incident. It silently broke
live SSO, and the CR status showed no error.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/pocketid.internal/pocketidoidcclient_v1alpha1.json
apiVersion: pocketid.internal/v1alpha1
kind: PocketIDOIDCClient
metadata:
    name: <app>
spec:
    allowedUserGroups:
        - name: app-admin # or app-ops / app-users — the CR name, hyphenated
          namespace: security
    callbackUrls:
        - "https://<app-hostname>/<oidc-callback-path>" # check app docs for exact path
    clientID: <app>
    launchUrl: "https://<app-hostname>/"
    logo:
        autoGenerate: false
    pkceEnabled: true # false only if the app cannot send a code_challenge (see Gotchas)
    secret:
        storeClientSecret: true
```

The operator creates a Secret for you. You do not copy anything into 1Password by hand. The app
must use the key names of the operator, or you change the key names to match what the app expects:

```yaml
secret:
    keys:
        clientID: <ENV_VAR_NAME_FOR_CLIENT_ID>
        clientSecret: <ENV_VAR_NAME_FOR_CLIENT_SECRET>
```

Then reference the Secret from the container of the app with `envFrom: [{ secretRef: { name:
<app>-oidc-credentials } }]`. The Secret name defaults to `<client-name>-oidc-credentials`. This
fully replaces the old manual-secret workflow.

> All YAML that this skill writes or changes must follow the field ordering rules in
> `.agents/instructions/yaml-conventions.md`.

## Step 2: Configure the App

### Native OIDC (env vars): bookboss pattern

```yaml
env:
    BOOKBOSS__OIDC__ISSUER: "https://id.dcunha.io"
    BOOKBOSS__OIDC__CLIENT_ID: "<app>"
    BOOKBOSS__OIDC__CLIENT_SECRET:
        valueFrom:
            secretKeyRef:
                name: <app>
                key: BOOKBOSS__OIDC__CLIENT_SECRET
```

### Servarr native OIDC: sonarr / radarr pattern

This pattern supports one user.

1. Set `SONARR__AUTH__METHOD: Oidc` and the `SONARR__AUTH__OIDC*` env vars. The callback is
   `/signin-oidc`.
2. Set `SONARR__AUTH__REQUIRED` to `Enabled`.
3. Put the pod CIDR in `SONARR__SERVER__TRUSTEDNETWORKS`. If you do not, the redirect URI comes out
   as `http://`.

Copy `kube/clusters/artemis/apps/media/sonarr/` or `radarr/`. The traps are in
`identity-stack.md` § Sonarr v5 and Radarr v7.

### Generic OAuth: Grafana pattern

```yaml
env:
    GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
    GF_AUTH_GENERIC_OAUTH_NAME: "Pocket-ID"
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID: "grafana"
    GF_AUTH_GENERIC_OAUTH_AUTH_URL: "https://id.dcunha.io/authorize"
    GF_AUTH_GENERIC_OAUTH_TOKEN_URL: "https://id.dcunha.io/api/oidc/token"
    GF_AUTH_GENERIC_OAUTH_API_URL: "https://id.dcunha.io/api/oidc/userinfo"
    GF_AUTH_GENERIC_OAUTH_SCOPES: "openid email profile groups"
    # Role mapping via JMESPath (groups claim):
    GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: "contains(groups[*], 'app_admin') && 'Admin' || contains(groups[*], 'app_ops') && 'Editor' || 'Viewer'"
```

The role mapping uses the Pocket-ID group names (`app_admin`, `app_ops`). If a name does not
match, every user gets `Viewer`. This cluster's own Grafana does not use env vars. It sets the same
keys in the `config:` block of its `Grafana` CR:
`kube/clusters/artemis/apps/observability/grafana/instance/grafana.yaml`.

### Shelfmark-style native OIDC (`AUTH_METHOD=oidc`)

Some apps expose OIDC through env vars with `AUTH_METHOD=oidc`:

```yaml
env:
    AUTH_METHOD: oidc
    OIDC_DISCOVERY_URL: "https://id.dcunha.io/.well-known/openid-configuration"
    OIDC_CLIENT_ID: <app>
    OIDC_ADMIN_GROUP: app_admin
    OIDC_AUTO_REDIRECT: "true"
```

Inject `OIDC_CLIENT_SECRET` from the Secret through `envFrom`. The callback URL is
`https://<hostname>/api/auth/oidc/callback`.

### Envoy Gateway OIDC via `components/envoy-oidc` (apps without native OIDC support)

Envoy handles the whole OIDC flow, so the app needs no sidecar. Do not use oauth2-proxy with Envoy
ExtAuth. Envoy does not forward `Set-Cookie` from the 302 of the auth service, so every callback
fails with "CSRF cookie not found".

Add the component to the app's `ks.yaml`. It renders a `SecurityPolicy` named `<app>-oidc` against
the HTTPRoute of the app. Copy the shape from `kube/clusters/artemis/apps/media/bazarr/ks.yaml`.
`grep -rln 'components/envoy-oidc' kube/clusters/artemis/apps` lists every consumer.

```yaml
dependsOn:
    - name: pocket-id-operator
      namespace: security
components:
    - ../../../../components/envoy-oidc
postBuild:
    substitute:
        APP: *app
```

There are two optional substitutions. `OIDC_HOST` defaults to `<app>.dcunha.io`.
`HTTP_ROUTE_TARGET` defaults to `<app>`, the HTTPRoute name.

Also write `app/oidcclient.yaml` as in Step 1, and add it to `app/kustomization.yaml`. Set
`callbackUrls: https://<host>/oauth2/callback`, `pkceEnabled: true` and
`secret.keys.clientSecret: client-secret`. The component reads the `<app>-oidc-credentials` Secret
of the operator, and Envoy needs the key to be exactly `client-secret`.
`kube/clusters/artemis/apps/media/bazarr/app/oidcclient.yaml` is the reference.

## Step 3: Test

Apply and commit as `.agents/skills/modules/test-and-commit.md` describes. Then:

```bash
kubectl rollout restart deployment <app> -n <namespace>
kubectl logs -n <namespace> deployment/<app> --tail=30
```

Go to `https://<app-hostname>`. It must redirect to the Pocket-ID login.

## Gotchas

- PKCE: default to `pkceEnabled: true`. If Pocket-ID returns `{"error":"Invalid code verifier"}`,
  the client promised PKCE and the app sent no `code_challenge`. Make the app send one. Do not
  assume that it cannot. There are two known cases. Both were checked against upstream source on
  2026-09-20:
    - django-allauth (Paperless-NGX) supports PKCE, but it is opt-in and off by default
      (`OAuth2Provider.pkce_enabled_default = False`). Add `"oauth_pkce_enabled": true` to the
      `settings` block of the app in `PAPERLESS_SOCIALACCOUNT_PROVIDERS`. Keep the client secret.
      A confidential client with PKCE is fine. An earlier version of this file said that allauth
      "loses the `code_verifier` between redirect and callback". That was wrong. allauth stores
      the verifier in session state and reads it back.
    - Spring Security (Komga) 6.5.x only sends a `code_challenge` for PUBLIC clients.
      `ClientSettings.requireProofKey` defaults to `false`, and Spring Boot has no client-side
      property to change it. A confidential client cannot do PKCE at all. Leave
      `pkceEnabled: false`, unless you also drop the secret and set
      `client-authentication-method: none` on both sides. Spring Security 7.x changes this
      default, so do not trust its main-branch docs for a 6.5 app.
- Existing account linking (django-allauth): if a local account with the same email already
  exists, allauth does not link it on the first OIDC login. To link by email, add
  `"EMAIL_AUTHENTICATION": true` to the `openid_connect` block in
  `PAPERLESS_SOCIALACCOUNT_PROVIDERS`.
- Grafana user conflict: if the existing user has `isExternal=false`, OAuth does not link it.
  Delete the user through the Grafana API, and let OAuth create it again.
- Home Assistant: HA core does not support an external OIDC auth provider, so `type: oidc` does
  not exist.
- `passThroughAuthHeader` requires JWT validation settings (a `jwt` block). Leave it out unless you
  also configure JWKS.

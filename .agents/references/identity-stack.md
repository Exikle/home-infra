# Identity Stack — lldap → Pocket-ID → tinyauth

This file explains how the parts of the identity chain of this cluster fit together. It also tells
you which auth mechanism to use. The facts were checked against the live cluster on 2026-08-24.

This file records no versions. Renovate changes them often, and a version string in prose is stale
within a week. Read the tags off the manifests:
`grep -E 'tag:|image:' kube/clusters/artemis/apps/security/{tinyauth,lldap}/app/helmrelease.yaml kube/clusters/artemis/apps/security/pocket-id/instance/pocketidinstance.yaml kube/clusters/artemis/apps/security/pocket-id/operator/ocirepository.yaml`.

## The chain

```
lldap (security ns)  →  Pocket-ID (security ns, id.dcunha.io)  →  app-level auth
  directory: users,        OIDC provider, passkey-only login.       one of:
  groups, passwords         Syncs users/groups FROM lldap.          - native app OIDC client
                            Never verifies lldap passwords —        - components/tinyauth
                            Pocket-ID is passwordless for             (which ALSO binds lldap
                            every account, LDAP-synced or not.        directly for password
                                                                      fallback login, AND is
                                                                      itself an OIDC provider)
```

Three consumers exist. You must know which one an app uses:

| Mechanism                       | Who is on it                                                                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Native `PocketIDOIDCClient`     | No roster here, because it changes. `kubectl get pocketidoidcclient -A`                                                              |
| `components/tinyauth` edge gate | No roster here, because it changes. `grep -rln 'components/tinyauth' kube/clusters/artemis/apps/`, or the ground-truth command below |
| tinyauth's own OIDC provider    | Immich (see § tinyauth is also an OIDC provider)                                                                                     |

`kubectl get pocketidoidcclient -A` is the ground truth for the first row. For the second row, run
this command and keep only the rows whose `HTTP` column is `tinyauth`:

```bash
kubectl get securitypolicy -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HTTP:.spec.extAuth.http.backendRefs[0].name'
```

`cortex/agentgateway` is a CORS policy. The `*-oidc` policies come from `components/envoy-oidc`.

No password ever reaches Pocket-ID. lldap has real password login. Its own web UI at
`ldap.dcunha.io` uses it for self-service profile management. Pocket-ID also uses a service-account
bind credential to read the directory. But Pocket-ID accepts only passkeys (WebAuthn), even for
users that come from LDAP. The upstream docs say: "Pocket ID only supports passwordless
authentication". The LDAP sync only tells Pocket-ID which users and groups exist. It is not a login
mechanism.

Password fallback exists only because tinyauth binds to lldap itself. The `TINYAUTH_LDAP_*`
environment variables in `security/tinyauth/app/helmrelease.yaml` set this up. The login page of
tinyauth offers "Login with Pocket-ID" (passkey). It also offers a username and password form that
tinyauth checks directly against lldap. Both paths use the same directory and the same groups.

## Pocket-ID: operator-managed, not app-template

`security/pocket-id/instance/` holds a `PocketIDInstance` CR. The operator
(`aclerici38/pocket-id-operator`) owns the Deployment, the Service and the HTTPRoute directly. It is
not an app-template HelmRelease.

Pocket-ID uses the shared CNPG cluster for Postgres, with cert-manager mTLS. The pod mounts
`postgres-pocket-id-cert` and `postgres-server-ca` through `spec.podTemplate.spec.volumes` and
`persistence.extraVolumeMounts`. The operator does not know this pattern, so you must copy it by
hand.

Always pin `spec.image` explicitly. The default image of the operator can be older than the schema
that your database already migrated to. Pocket-ID refuses to start when the schema is newer than
the app version.

`security/pocket-id/operator/helmrelease.yaml` sets `instance.enabled: false`. The instance is a
standalone CR (`instance/pocketidinstance.yaml`). The chart does not manage it. The operator still
manages every `PocketIDOIDCClient` and `PocketIDUserGroup` CR across the cluster, wherever the
instance CR lives.

Read these live instance settings before you change anything:

| Field                    | Value                                   | Why it matters                                               |
| ------------------------ | --------------------------------------- | ------------------------------------------------------------ |
| `image`                  | digest-pinned (`pocketidinstance.yaml`) | must be the same as or newer than the DB's migrated schema   |
| `ldap.userSearchFilter`  | `(objectClass=person)`                  | the default, so the `admin` of lldap is in scope (see below) |
| `ldap.softDeleteUsers`   | `true`                                  | a user that leaves the filter is disabled, not removed       |
| `ldap.adminGroupName`    | `lldap_admin`                           | a member of this group is a Pocket-ID admin                  |
| `metrics.enabled` / port | `true` / `9464`                         | the `pocket-id` ServiceMonitor in `instance/` scrapes it     |

`security/pocket-id/operator/` ships its own alert rules and a ServiceMonitor. The rules include
`PocketIDOIDCClientRotationFailing` and `PocketIDOIDCClientRotationOverdue`. So a failed rotation of
a client secret sends an alert.

### Groups: the CR name is not the group name

Three `PocketIDUserGroup` CRs exist. The `metadata.name` of each one is different from the
`spec.name` that apps match on:

| CR name (`kubectl get pocketidusergroup -n security`) | `spec.name` (what goes in the group list of an app) |
| ----------------------------------------------------- | --------------------------------------------------- |
| `app-admin`                                           | `app_admin`                                         |
| `app-ops`                                             | `app_ops`                                           |
| `app-users`                                           | `app_users`                                         |

The CR name uses hyphens. The group name uses underscores. If you write a `TINYAUTH_APPS_*_GROUPS`
value or an app-side group ACL with hyphens, it matches nobody. Depending on the app, the result is
that everyone gets in, or nobody does. But the `allowedUserGroups[].name` of a `PocketIDOIDCClient`
uses the CR name (`app-admin`). The two conventions sit side by side, and it is easy to mix them up.

## lldap wiring — the adoption gotcha

The `spec.ldap` block of Pocket-ID matches users and groups by the LDAP `uuid` attribute
(`attributeMapping.userUniqueIdentifier`/`groupUniqueIdentifier: uuid`). This matches the upstream
Pocket-ID example for lldap (`example_configs/pocket-id.md`). That example uses the bind DN
`cn=admin,ou=people,...`, not `uid=admin`. It uses `uuid` for unique identifiers, and
`uid`/`mail`/`givenName`/`sn`/`jpegPhoto`/`member`/`cn` for the other attributes.

Pocket-ID can already have local users or groups from before LDAP, with the same username or name as
their lldap counterparts. In that case, the sync tries to `INSERT` a new row. The insert collides
with the `username`/`name` UNIQUE constraint. Postgres aborts the transaction, and `SyncLdap` fails
on every cycle. The `ldap_id` column on an existing local row does not prove a real link. Pocket-ID
puts the username there as a placeholder for purely local accounts.

To fix this, adopt the rows in place. Do not delete and recreate them.

1. Get the real lldap `uuid` of each user or group from the lldap GraphQL API. Send
   `POST /auth/simple/login` to get a bearer token. Then send `POST /api/graphql` with
   `{ users { id uuid email } }` or `{ groups { id displayName uuid } }`.
2. In Postgres, run `UPDATE users/user_groups SET ldap_id = '<real-uuid>' WHERE username/name = '<name>'` for each row.

This causes no disruption. Passkeys, sessions and audit history all stay. If you delete and recreate
the rows instead, every real user must register their passkey again.

If `userSearchFilter` is the default `(objectClass=person)`, the sync also picks up the bootstrap
`admin` account of lldap. Its `uid` is `admin`, which probably collides with the local `admin`
account of Pocket-ID. You have two choices:

- Exclude it with `(&(objectClass=person)(!(uid=admin)))`.
- If you want it synced, adopt it like a real user. Map its real lldap `uuid` in too.

Look out for one more trap. With `softDeleteUsers: true`, an account whose `ldap_id` is older than
its exclusion from the search filter looks "removed from the directory". Pocket-ID then soft-deletes
it with no warning. If that happens, set its stale `ldap_id` to `NULL` and enable the account again.

## Gating apps: tinyauth and envoy-oidc

Two edge gates exist. Both are Envoy Gateway `SecurityPolicy` components that you add to an app.

`components/envoy-oidc` is the common one. It uses `SecurityPolicy.oidc`: Envoy does the OAuth flow
itself against Pocket-ID, with a session for each app. To see which apps use it, run
`grep -rln 'components/envoy-oidc' kube/clusters/artemis/apps`. It has no shared session and no ACL
environment variables. The `allowedUserGroups` of the `PocketIDOIDCClient` of the app controls
access.

`components/tinyauth` uses `SecurityPolicy.extAuth` and points at the shared tinyauth pod. To see
which apps use it, run `grep -rln 'components/tinyauth' kube/clusters/artemis/apps/`. It gives:

- One shared login and session across every app that it protects (a cookie on `.dcunha.io`).
- Passkey login through Pocket-ID, with lldap password login as a fallback.
- Group ACLs for each app, set with environment variables.

Apps with real user models (Immich, Grafana, Paperless, and others) keep their native
`PocketIDOIDCClient` for identity inside the app. tinyauth is a gate. It does not pass identity on
to the app. The two layers work well together.

These rules apply when you wire an app into tinyauth. The full walkthrough is in
`.agents/skills/add-tinyauth-app/SKILL.md`.

- Since v5.1.0, every app ACL needs THREE keys, not two:

    | Key                                    | Checked for              | If unset                  |
    | -------------------------------------- | ------------------------ | ------------------------- |
    | `TINYAUTH_APPS_<NAME>_OAUTH_WHITELIST` | OAuth email, first       | denies every OAuth user   |
    | `TINYAUTH_APPS_<NAME>_OAUTH_GROUPS`    | Pocket-ID session groups | allows any Pocket-ID user |
    | `TINYAUTH_APPS_<NAME>_LDAP_GROUPS`     | lldap password session   | allows any lldap user     |

    The whitelist is the trap. The v5.1.0 rules engine checks it against the OAuth email before the
    group check. An empty whitelist does not mean "no filter". `CheckFilter` returns
    `ErrFilterEmpty`, which resolves to `EffectDeny`. So an app that worked on v5.0.x locks out every
    passkey user after the upgrade. LDAP password login keeps working, so the fault looks like a
    Pocket-ID fault. Set the whitelist to the match-all regex `"/.*/"`. Then the group lists stay the
    real gate:

    ```yaml
    TINYAUTH_APPS_<APP>_OAUTH_WHITELIST: "/.*/"
    TINYAUTH_APPS_<APP>_OAUTH_GROUPS: app_admin,app_ops
    TINYAUTH_APPS_<APP>_LDAP_GROUPS: app_admin,app_ops
    ```

    Group names use underscores (`app_admin`). See § Groups above. Two group keys exist because
    tinyauth checks groups for each login provider separately. The same name works for both,
    because Pocket-ID syncs its groups from lldap.

    Correction for v5.1.3 (read on 2026-08-24 in `internal/service/access_controls_rules.go`): an
    empty OAuth whitelist now returns `EffectAbstain`, not `EffectDeny`. Under the default `allow`
    policy, an abstain resolves to allowed. So the lockout above no longer happens by itself. But
    this cluster sets `TINYAUTH_AUTH_ACLS_POLICY` to `deny`, and under `deny` an abstain resolves to
    denied. So every app with an ACL still needs the `/.*/` whitelist. The reason is now the
    opposite of the original one.

- `TINYAUTH_AUTH_ACLS_POLICY: deny` is set. The default is `allow`. An app with no
  `TINYAUTH_APPS_*` entry at all abstains on `RuleUserAllowed`, so tinyauth denies it. Without this
  setting, tinyauth admits every signed-in user to such an app. This guardrail makes it safe to add
  apps. The cost is that a new protected app stays locked until its ACL keys exist. This was checked
  before the setting was turned on. `IPAllowedRule` returns `EffectAllow` when no allow-list is set
  (`access_controls_rules.go:265`). So the negated `if !Evaluate(RuleIPAllowed)` check in
  `proxy_controller.go:140` cannot lock everyone out.

    `deny` reaches further than the app ACLs. `AuthService.IsEmailWhitelisted`
    (`auth_service.go:322`) checks the global `TINYAUTH_OAUTH_WHITELIST` through
    `policyEngine.EvaluateFunc`. An unset whitelist returns `EffectAbstain`, and under `deny` that
    resolves to denied. This check runs at the OAuth callback in `oauth_controller.go`, before any
    app ACL. So every Pocket-ID login fails with "The user with username &lt;email&gt; is not
    authorized to login", and that includes the Immich login. A grep for `Evaluate(` does not find
    this call. The call is `EvaluateFunc`, and it is the only other caller in the tree.

    So `TINYAUTH_OAUTH_WHITELIST: "/.*/"` is required whenever the policy is `deny`. It does not
    make access looser. The `allowedUserGroups: app-users` of the tinyauth client in Pocket-ID
    decides who can reach tinyauth at all. The `TINYAUTH_APPS_*_GROUPS` keys of each app decide
    which apps they reach. The global whitelist is an email filter that this cluster does not use.

- `TINYAUTH_LABELPROVIDER: none` is deliberate. The label-provider auto-detect of v5.1.0 needs an
  in-cluster ServiceAccount token, and the pod does not mount one. If you leave the key unset,
  tinyauth logs detection failures at boot. ACLs here come from `TINYAUTH_APPS_*` environment
  variables, never from labels.
- ext_authz intercepts every external request on the route, not only browser requests. Mobile apps,
  API tokens and webhooks that call `*.dcunha.io` break unless you exempt them with
  `TINYAUTH_APPS_<NAME>_PATH_ALLOW` regexes. Internal `svc.cluster.local` traffic never goes through
  the gateway, so the gate does not affect it.
- Sessions live in sqlite on an emptyDir (`/data/tinyauth.db`). v5 has no `TINYAUTH_SECRET`, and
  sessions are database rows. So every restart of the tinyauth pod logs everyone out of every
  protected app. This trade-off is deliberate for now: a restart revokes all sessions in the cluster
  at once. Otherwise a session lasts `TINYAUTH_AUTH_SESSIONEXPIRY` (604800s = 7 days). That is also
  how long a user that you disable in lldap keeps access.
- The pod runs as the `tinyauth` user (1000) of the image, with a read-only root filesystem. The
  sqlite database and the resources directory live on the `/data` emptyDir. The signing-key secret
  is mounted with mode `0440`, so that `fsGroup: 1000` can read it. Mode `0400` is readable by root
  only, and it breaks OIDC.

## Handing the app an authenticated session, not just a gate

By default, tinyauth is a doorman. It proves that you can pass, but the app does not know who you
are. So an app with its own login shows that login anyway. Two mechanisms correct this. Which one
you use depends on what the app supports.

tinyauth always sets `Remote-User`, `Remote-Name`, `Remote-Email`, `Remote-Groups` and `Remote-Sub`
on the authenticated response (`proxy_controller.go:261-271`). But none of them reach the backend
unless the `headersToBackend` list of the SecurityPolicy names them. That list is the whole
contract. `components/tinyauth/securitypolicy.yaml` holds `Authorization`, `Location` and
`Set-Cookie`. When an app that reads the `Remote-*` headers arrives, add them there.

If an app has no trusted-header mode at all, tinyauth can create credentials for it instead:

```yaml
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_USERNAME: <user>
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_PASSWORDFILE: /secrets/oidc/<app>-basic-password
```

`proxy_controller.go:321-325` reads the password file and sets `Authorization: Basic <base64>`.
This replaces the request `Authorization` header that line 309 echoes. It needs `Authorization` in
`headersToBackend`, and it is there. The tinyauth source read on 2026-08-24 has this feature:
`model.AppBasicAuth`, `config.go:328`. To read the tinyauth tag that runs now, run
`grep -E 'tag:' kube/clusters/artemis/apps/security/tinyauth/app/helmrelease.yaml`.

No app uses this today, because bazarr moved to `components/envoy-oidc`. The pattern is:

- The own auth of the app is set to `basic`.
- The password lives in the 1Password item of the app as `TINYAUTH_BASIC_PASSWORD`.
- The `tinyauth` ExternalSecret pulls it with a second `dataFrom.extract` and renders it as
  `<app>-basic-password`.

The credential belongs to the app. tinyauth only presents it.

Keep app credentials in the `artemis` vault. The `onepassword-connect` ClusterSecretStore serves the
vaults in priority order: `artemis: 1`, `infrastructure: 2`, `frostlink: 3`. A bare `key: <name>`
resolves to the vault with the highest priority that holds that title. So an item with the same name
in `artemis` hides the one in `infrastructure`, with no warning. Before you create an item, search
every vault (`op item list --vault <v>` for each vault, not only `artemis`).

The password file path says `oidc`, and that is deliberate. The `persistence.oidc` entry mounts the
whole `tinyauth` Secret at `/secrets/oidc`, so every key in it lands there. If you rename the mount,
`TINYAUTH_OIDC_PRIVATEKEYPATH` moves, and the cached JWKS of Immich breaks. See § tinyauth is also
an OIDC provider. Keep the name.

### bazarr: own auth deliberately off

envoy-oidc cannot hand a credential to the app. With the own `basic` auth of bazarr turned on,
users had to log in twice: first at Pocket-ID, then in a browser popup. On 2026-09-29 the
`auth.type` of bazarr was set to `null`. Users now log in once, at Pocket-ID. The accepted cost:
anything inside the cluster can reach the UI with no auth, and the UI page shows the API key. This
is possible because `media` has no NetworkPolicy.

- `auth.type` is not in git. It lives in `config.yaml` on the PVC of bazarr. To turn auth back on,
  use the API, not the file. Send `POST /api/system/settings` with `X-API-KEY`,
  `settings-auth-type=form` (no popup) or `basic`, `settings-auth-username`, and
  `settings-auth-password=<plaintext>`. bazarr hashes the password with MD5 on the server
  (`bazarr/app/config.py:748`).
- The probes work either way. Upstream declares `/api/system/ping` as unauthenticated
  (`bazarr/api/system/ping.py`, no `@authenticate`). Auth guards only the UI blueprint catch-all in
  `bazarr/app/ui.py`.

## Sonarr v5 and Radarr v7: native OIDC, one user

Sonarr v5 and Radarr v7 have their own OIDC login (`<APP>__AUTH__METHOD: Oidc`). Both are
pre-releases. Sonarr has it from `5.0.0.2569` (Sonarr PR #8950). Radarr has it from `7.0.0.10815`
(Radarr PR #11927). Both apps are wired the same way. The notes below use the Sonarr names. The
Radarr names are the same with a `RADARR` prefix (`RADARR_OIDC_USER_ID` on the `radarr` item,
`radarr-oidc-credentials`). Prowlarr has no OIDC. Do not copy this pattern to it.

- It admits exactly one user. Sonarr matches `SONARR__AUTH__OIDCUSERIDENTIFIER` against the `sub`
  claim, or against the email when `email_verified` is true. Sonarr ignores group claims. The
  `allowedUserGroups` of the client decides who can reach the login at all. The value is the
  Pocket-ID user ID (the `sub`). It is kept as `SONARR_OIDC_USER_ID` on the `sonarr` 1Password
  item, because gitleaks flags a literal UUID in a manifest as a generic API key. To recover it,
  call `GET /api/users` with the `pocket-id-static-api-key` Secret.
- `SONARR__AUTH__REQUIRED` must be `Enabled`. Requests arrive through Envoy from a private address,
  and `DisabledForLocalAddresses` skips the login for a private address. So that value turns
  the login off completely.
- `SONARR__SERVER__TRUSTEDNETWORKS` must hold the pod CIDR. By default, Sonarr trusts
  `X-Forwarded-Proto` only from loopback. Behind Envoy, it then builds an `http://` redirect URI,
  and Pocket-ID rejects it ("redirect_uri ... is not registered"). You see this as a 500 on
  `/login/sso`.
- The API key still works. `X-Api-Key` and `?apikey=` are separate schemes that sit beside OIDC.
  So in-cluster callers keep working: Prowlarr, seerr, the arr MCP tools and `refresh-series.sh`.
  `/ping` stays anonymous for the probes.
- An incomplete configuration falls back to Forms login with a health warning, not an error. If the
  login page shows a username form, look at the four `OIDC*` environment variables and the
  `sonarr-oidc-credentials` Secret.
- "Correlation failed" on a later login is upstream issue #9099. The browser caches the
  `/login/sso` redirect. Clear the site cache.
- The callback is the ASP.NET default `/signin-oidc`. Sign-out returns to `/signout-callback-oidc`.

## The login flow is one visible page, by design

`TINYAUTH_OAUTH_AUTOREDIRECT: pocketid` skips the provider picker of tinyauth and sends the user
straight to Pocket-ID. So the only login page that anyone sees is the passkey prompt at
`id.dcunha.io`. The tinyauth `PocketIDOIDCClient` also sets `skipConsent: true`, so there is no
consent screen either.

Auto-redirect does not remove the lldap password fallback. It fires only when the login request
carries a `redirect_uri` or `oidc_ticket` screen parameter, that is, when a protected app sent you
there (`frontend/src/pages/login-page.tsx`). If you open `auth.dcunha.io` directly, it still shows
the full page with the username and password form. This is the break-glass path when Pocket-ID is
down. The same file calls `setIsOauthAutoRedirect(false)` when OAuth fails. So a failed passkey hop
also falls back to the form, and it does not loop.

Pocket-ID sees exactly one client for this whole path: Artemis SSO (`clientID` `tinyauth`).
Pocket-ID cannot see the tinyauth-gated apps. So the consent and authorize screen names the gate,
never the app that you asked for. This follows directly from the use of one shared client. It is
also why authorization for each app must live in `TINYAUTH_APPS_*`.

## tinyauth is also an OIDC provider

Since v5.1.0, tinyauth does more than consume Pocket-ID. It also issues OIDC to apps behind it.
Immich authenticates against tinyauth (`auth.dcunha.io`), not against Pocket-ID directly, through
`TINYAUTH_OIDC_CLIENTS_IMMICH_*`. So the login flow of Immich is
`Immich → tinyauth → Pocket-ID → lldap`. The LDAP password form of tinyauth is an alternative
second hop. A `media/immich` `PocketIDOIDCClient` also exists. Do not take its presence as proof
that Immich talks to Pocket-ID.

Two things break it:

- The signing keys come from the `tinyauth` 1Password secret, mounted read-only at `/secrets/oidc`
  (`TINYAUTH_OIDC_PRIVATEKEYPATH` / `_PUBLICKEYPATH`). They are deliberately not on `/data`, which
  is an emptyDir. Keys on `/data` change on every pod restart. Each change makes every cached JWKS
  invalid, and Immich login then breaks until the clients fetch the keys again. If you move the key
  storage, the new place must survive a restart.
- `TINYAUTH_OIDC_CLIENTS_IMMICH_TRUSTEDREDIRECTURIS` holds four entries. One of them is the
  `app.immich:///oauth-callback` mobile deep link. If you drop it, only the phone app breaks. This
  is easy to miss when you test in a browser.

tinyauth itself is routed at `auth.dcunha.io` on `edge-gateway`. It must be reachable from every
place where a protected app is reachable, including from outside the LAN. The same applies to
pocket-id (`id.dcunha.io`).

## Cross-namespace grants: ResourceSet, not per-namespace files

The `tinyauth` Service lives in `security`. An app in another namespace (for example `media`) can
point its `SecurityPolicy.extAuth` at it only after a `ReferenceGrant` exists in `security`.
Gateway API requires the namespace that owns the resource to declare the grant, never the consumer.
This rule stops a namespace from granting itself access to anything.

The grants come from one `ResourceSet` at `security/tinyauth/app/resourceset.yaml`. The
`ResourceSet` kind (`fluxcd.controlplane.io/v1`) comes from `flux-operator`, which this cluster
already runs, and it works here. `spec.inputs` is a flat list of namespaces. `spec.resources` is a
template that makes one `ReferenceGrant` for each input. The template uses `<< inputs.namespace >>`
syntax, not `{{ }}`, so that it does not clash with Helm.

To add a namespace, add one line to `spec.inputs`. Everything is inline: there is no external
template path and no file for each namespace. You can test it with `apply-ks` like everything else.
One input line for each namespace is better than a file for each namespace or nested
Kustomizations, because you cannot test those with `apply-ks`.

The template must set `metadata.namespace` explicitly on what it generates. A `ResourceSet` does not
give its generated resources a default namespace. A Flux Kustomization has `targetNamespace` for
this, but a `ResourceSet` does not.

The `ResourceSet` makes one `ReferenceGrant` for each `spec.inputs` entry, named
`<namespace>-grant`. Read the inputs from the tree, not from a list here:
`sed -n '/inputs:/,/resources:/p'
kube/clusters/artemis/apps/security/tinyauth/app/resourceset.yaml`, or
`kubectl get referencegrant -n security`. To add the first app in a new namespace, add a line there
and add the `SecurityPolicy` of the app. A missing grant does not show as a login failure. It shows
as the `SecurityPolicy` at `Accepted=False` with the reason `RefNotPermitted`.

## Flux ordering: the operator installs the CRDs, so it goes first

`pocket-id-operator` must not depend on `pocket-id` (the instance). The instance applies a
`PocketIDInstance` CR, and the HelmRelease of the operator installs the CRD for it. Nothing in
`kube/clusters/artemis/bootstrap/helmfile.d` installs those CRDs separately. On a running cluster you
do not see the problem, but a rebuild from nothing deadlocks. The instance cannot apply without the
CRD, and the operator that installs the CRD waits for the instance to go Ready. The graph is:

```text
pocket-id-operator  (no deps — installs the CRDs)
  └── pocket-id     (the PocketIDInstance CR)
  └── pocket-id-groups
        └── pocket-id-extclients
```

`security/tinyauth` also depends on `pocket-id-operator`. That is correct for the same reason,
because tinyauth applies a `PocketIDOIDCClient`.

## Forgejo admin is driven by the Pocket-ID `app_admin` group

The Forgejo OAuth2 source has `AdminGroup = app_admin` and `GroupClaimName = groups`. So on every
OIDC login, Forgejo calculates `is_admin` again from the groups claim. This can remove admin rights,
not only grant them. If the claim does not arrive, Forgejo sets `is_admin = 0`, and the next login
undoes any manual promotion.

If the `Scopes` field is empty, Forgejo never requests the `groups` scope, and Pocket-ID never sends
the claim. A correct configuration reads `Scopes = ["groups"]`. Forgejo stores it as a JSON array.

To read the current values, run:

```bash
ssh root@10.10.99.24 "sqlite3 /var/lib/forgejo/data/forgejo.db \
  \"SELECT json_extract(cfg,'\$.AdminGroup'), json_extract(cfg,'\$.GroupClaimName'), \
     json_extract(cfg,'\$.Scopes') FROM login_source;\""
```

This has two results:

- If you remove yourself from `app_admin` in Pocket-ID, Forgejo removes your admin rights at the
  next login. The local `administrator` account (`is_admin=1`, `login_type=0`) is the break-glass
  path.
- This setting lives in the database of Forgejo, not in `app.ini`. `ansible/roles/forgejo` cannot
  manage it and cannot stop the fault from coming back, because an auth source is API and UI state.

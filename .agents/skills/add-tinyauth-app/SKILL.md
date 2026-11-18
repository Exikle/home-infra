---
name: add-tinyauth-app
description: Put an app behind tinyauth via Envoy Gateway ext_authz, for apps with no native OIDC support. Use for "protect X with tinyauth", "gate X behind tinyauth", "shared login for X", or "ext_authz for X". Scoped to the Artemis cluster.
---

# Skill: Add Tinyauth Protection to an App

This skill puts an app behind the shared `tinyauth` forward-auth service. A forward-auth service
answers "is this request allowed?" before Envoy sends the request to the app. tinyauth uses a
Pocket-ID passkey login, with an lldap password as the fallback. Every protected app shares one
login and one session.

tinyauth is the standard gate for apps that have no native OIDC. You can also put it in front of
apps that have native OIDC. The alternative is `components/envoy-oidc`, which is a per-app Envoy
OIDC client (see `.agents/skills/add-oidc-app/SKILL.md`). Apps with real user models also keep
their native `PocketIDOIDCClient` for in-app identity. tinyauth does not replace it.

Read all of `.agents/references/identity-stack.md` before you start. It covers the lldap, Pocket-ID
and tinyauth chain, the `ResourceSet` grant mechanism, the session handoff, and every gotcha that
the build found.

> Since 2026-08-24, `TINYAUTH_AUTH_ACLS_POLICY` is `deny`. If an app has no `TINYAUTH_APPS_*`
> entry, tinyauth denies it. It does not leave the app open. This is the opposite of the old
> failure mode. Before, if you forgot Step 3, the app stayed wide open. Now you are locked out of
> it. The gate fails closed. A 403 from it does not mean that the gate is broken.

---

## Step 1: Add the component to the app's `ks.yaml`

```yaml
components:
    - ../../../../components/tinyauth
```

If the app has no in-app login, remove its `oidcclient.yaml` and its `pocket-id-operator`
dependency. tinyauth is then the only OIDC client. If the app uses Pocket-ID for its own user
model, keep both.

Do not add a `dependsOn` on tinyauth. The repo removed availability-gating edges on purpose. The
`SecurityPolicy` applies whether tinyauth is healthy or not, and Envoy programs it when the backend
appears.

## Step 2: Grant the app's namespace access to the tinyauth Service

Gateway API requires a `ReferenceGrant`. The namespace that owns the target resource declares it.
Here that is `security`, where the `tinyauth` Service lives. The consumer never declares it. The
`ResourceSet` at `kube/clusters/artemis/apps/security/tinyauth/app/resourceset.yaml` generates the
grant.

1. Read the `spec.inputs` of that `ResourceSet`.
2. If the namespace is already in the list (`media` is), skip the rest of this step.
3. If it is not, add one line for the new namespace, in alphabetical position:

```yaml
spec:
    inputs:
        - namespace: media
        - namespace: <new-namespace>
```

Do not create a per-app or per-namespace file. The repo tried that and reverted it twice. Also,
`inputsFrom` on a `ResourceSet` is namespace-scoped (the CRD says: "an input provider resource in
the same namespace as the ResourceSet"). So you cannot use the `external-endpoints` provider
pattern to move this next to the app. The repo evaluated that pattern and rejected it on
2026-08-24.

## Step 3: Set the per-app ACL (three keys, all mandatory)

Add these keys to the container env in `security/tinyauth/app/helmrelease.yaml`:

```yaml
env:
    TINYAUTH_APPS_<APPNAME_UPPERCASE>_OAUTH_WHITELIST: "/.*/"
    TINYAUTH_APPS_<APPNAME_UPPERCASE>_OAUTH_GROUPS: app_admin,app_ops
    TINYAUTH_APPS_<APPNAME_UPPERCASE>_LDAP_GROUPS: app_admin,app_ops
```

| Key                | Checked for              | If unset, under `policy: deny` |
| ------------------ | ------------------------ | ------------------------------ |
| `_OAUTH_WHITELIST` | OAuth email, first       | abstains → denies OAuth users  |
| `_OAUTH_GROUPS`    | Pocket-ID session groups | abstains → denies              |
| `_LDAP_GROUPS`     | lldap password session   | abstains → denies              |

tinyauth checks groups for each login provider, so there are two group keys. The same underscored
name works for both, because Pocket-ID syncs its groups from lldap.

- `APPNAME` must match the subdomain of the app. ext_authz finds the ACL from the request host
  (`frigate.dcunha.io` → `frigate`). `auth.subdomainsEnabled` defaults to true, so you do not need
  `_CONFIG_DOMAIN`.
- Group values use underscores (`app_admin`). They do not use the hyphenated `PocketIDUserGroup`
  CR name (`app-admin`). See `identity-stack.md` § Groups.
- `"/.*/"` is a match-all regex, not a placeholder. Keep it. The group lists are the real gate.
- Never remove the global `TINYAUTH_OAUTH_WHITELIST: "/.*/"`. Under `policy: deny`, an unset global
  whitelist abstains. It then denies _every_ Pocket-ID login at the OAuth callback, before any app
  ACL runs. This includes Immich. See `identity-stack.md` § Gating apps.

## Step 4: Optional, hand the app an authenticated session

By default, tinyauth only gates the route. An app with its own login still shows that login. If the
app accepts trusted headers, add the headers that it needs to `headersToBackend` in
`components/tinyauth/securitypolicy.yaml`. tinyauth sets `Remote-User`, `Remote-Name`,
`Remote-Email`, `Remote-Groups` and `Remote-Sub`. None of them reach the backend unless you name
them there.

If the app has no header-auth mode, tinyauth can create basic-auth credentials instead:

```yaml
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_USERNAME: <user>
TINYAUTH_APPS_<APP>_RESPONSE_BASICAUTH_PASSWORDFILE: /secrets/oidc/<app>-basic-password
```

1. Search every 1Password vault for an item with the same title. A duplicate title in a
   higher-priority vault silently hides the real item.
2. Put the password in the app's own 1Password item in the `artemis` vault.
3. Pull the password into the `tinyauth` ExternalSecret with an extra `dataFrom.extract`. It lands
   under `/secrets/oidc/`, because the whole Secret is mounted there.
4. Turn on the app's own auth. `Authorization` is already in `headersToBackend`.

No app uses this today. `identity-stack.md` § Handing the app an authenticated session describes
the mechanics.

## Step 5: Test live before committing

Follow `.agents/skills/modules/test-and-commit.md`. Edit in a worktree:
`mise run //:wt:new feat/<slug>`.

1. Run `test-ks` twice: once for `security tinyauth`, and once for the namespace and
   Kustomization of the app. `test-ks` takes one namespace for each call.
2. Request the app and read the headers. Expect `HTTP/2 401`, and an `x-tinyauth-location` header
   that points at the login of tinyauth:

```bash
curl -sI https://<app-hostname>/
```

3. Dump the parsed configuration, to make sure that the ACL landed. `tinyauth config` is the
   fastest way to see what tinyauth actually uses:

```bash
kubectl exec -n security <tinyauth-pod> -c app -- /tinyauth/tinyauth config
```

> Filter the dump before you paste it anywhere: `| grep -vi 'password\|secret'`. The dump is not
> redacted. It prints `ldap.bindPassword` and the OIDC `clientSecret` in plaintext.

4. Do a negative test against your own account. This is the only reliable way to make sure that
   the group ACL works:
    1. Temporarily set the group requirement to a group that does not exist.
    2. Make sure that tinyauth denies your own authenticated session.
    3. Set the group back, and make sure that access returns.

A positive-only test cannot tell "correctly allowed" from "no ACL enforced at all".

---

## Gotchas

- ext_authz intercepts every external request on the route, not only browsers. Mobile apps, API
  tokens and webhooks break unless you exempt them. Exempt a path with
  `TINYAUTH_APPS_<NAME>_PATH_ALLOW`, or the IP of the caller with `_IP_BYPASS`. Internal
  `svc.cluster.local` traffic never touches the gateway, so tinyauth does not affect it. That is
  why probes and app-to-app calls keep working.
- Label-based ACL discovery watches only `networking.k8s.io/v1 Ingress`, never Gateway API
  `HTTPRoute`. This cluster uses only Gateway API, so `TINYAUTH_LABELPROVIDER: none` is permanent.
  If you mount a ServiceAccount token, the provider still has nothing to read. Always use the
  explicit `TINYAUTH_APPS_*` env.
- The login flow shows one page. `TINYAUTH_OAUTH_AUTOREDIRECT: pocketid`, plus `skipConsent` on the
  client, sends users straight to the passkey prompt. Auto-redirect only fires when the request
  carries `redirect_uri` or `oidc_ticket`. If you go to `auth.dcunha.io` directly, it still shows
  the lldap password form. That is the break-glass path. Do not "fix" it.
- Pocket-ID names the gate, not the app. Its consent and authorize screen says _Artemis SSO_,
  because tinyauth is its only client. Pocket-ID cannot see any app that tinyauth gates. For that
  reason, per-app authorization must live in `TINYAUTH_APPS_*`.
- Sessions live in sqlite on an emptyDir (`/data/tinyauth.db`). Each restart of a tinyauth pod
  logs everyone out of every protected app. This is deliberate for now, because a restart revokes
  all sessions cluster-wide. Otherwise, sessions last `SESSIONEXPIRY` (7 days). That is also the
  revocation lag for a user that you disable in lldap. `LDAP_GROUPCACHETTL` adds up to 15 min of
  lag on group changes.
- The password fallback goes from tinyauth to lldap directly, not through Pocket-ID. Pocket-ID is
  passkey-only, even for LDAP-synced users. Do not configure `TINYAUTH_AUTH_USERS`. It is a second
  credential store that nothing syncs.

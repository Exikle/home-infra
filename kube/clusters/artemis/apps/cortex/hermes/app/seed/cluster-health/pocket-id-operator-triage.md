# Pocket-ID operator triage

Neither class below is auto-fixable. Report both to the operator.

## Operator CrashLoop: version-skew halt (seen 2026-08-19, cleared)

The operator halts on purpose when it finds a pocket-id release that it does not support. The log
line is `Pocket-id version is unsupported by this operator; halting`, with `detectedVersion` and
`firstUnsupportedVersion`. The operator exits 1 on every restart. So `restartCount` goes up
steadily (498 restarts over about 6 days), and `LeaderElection` events repeat about once a minute.
A short CrashLoop levels off instead. A pod delete does not help, because every restart hits the
same gate. The pocket-id workload stays `1/1 Running` and needs no restart. As a side effect, the
`pocket-id-extclients` Kustomization fails its health check, because the `PocketIDOIDCClient` CRs
stay `InProgress`.

Operator fix: upgrade the operator to a version that supports the installed pocket-id. Or pin
pocket-id to a release that the operator supports (the operator log shows `latestTestedVersion`).
The operator was upgraded after this case.

## PocketIDOIDCClientPKCESupported (config gap, not a crash)

Annotation:
`The PocketIDOIDCClient <namespace>/<name> supports PKCE but has it disabled. Set spec.pkceEnabled: true to enable it.`
The CR lives in the namespace of its app. The operator pod is
healthy, and the CR has `spec.pkceEnabled: false`. The fix is a git edit that sets
`spec.pkceEnabled: true`, never a live patch. The alert clears after the next reconcile of the
operator. Report which client, how long the alert has fired, and that the operator is healthy.

The last client closed on 2026-10-16 04:00Z. A newly onboarded OIDC client can raise this alert
again. The fix is the same.

## Recurrence log (open cases only)

Format and rules are in `SKILL.md` § Documented cases. No open Pocket-ID case at 2026-10-21. Full history (24 entries) is archived in `/opt/data/workspace/cluster-health/archive/pocket-id-operator-triage.full.md`.

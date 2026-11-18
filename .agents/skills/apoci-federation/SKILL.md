---
name: apoci-federation
description: Set up, repair, or tune an apoci OCI registry — ActivityPub federation between instances (cross-instance follow, artifact mirroring, webfinger, peer verification) and registry garbage collection and retention (keepLastN vs maxAge, pinnedGlobs, excludedRepos). Use for "federate apoci", "apoci ActivityPub follow", "apoci federation peer", "mirror apoci artifacts between instances", "apoci webfinger", "apoci retention", "apoci garbage collection", "registry GC", or "apoci registry disk full". Covers Artemis and Frostlink.
---

# Skill: apoci Federation

This skill manages ActivityPub federation between apoci registry instances, and the garbage
collection of each registry.

## Background

Each apoci instance is an ActivityPub actor (`@registry@<domain>`). Federation is follow-based:

- When A follows B, B mirrors its artifact pushes to A.
- For full sync in both directions, each instance must follow the other.
- `autoAccept: mutual` (set on both Artemis and Frostlink) accepts a follow-back automatically if
  you already follow the sender.

Instances:

| Instance  | Registry URL                     | Actor                     |
| --------- | -------------------------------- | ------------------------- |
| Artemis   | `https://registry.dcunha.io`     | `@registry@dcunha.io`     |
| Frostlink | `https://registry.frostlink.dev` | `@registry@frostlink.dev` |

Each pod has the `apoci` binary. Its default configuration file, `/apoci/config/apoci.yaml`, already
holds the endpoint and the path of the admin token. So the commands below pass no `-c` flag.

## Federate Two Instances (bidirectional)

### Step 1: Send the follow from A to B

Use the actor URL. A domain-only webfinger lookup does not always resolve in-cluster.

```bash
# Artemis follows Frostlink
kubectl --context artemis -n fediverse exec deploy/apoci -c app -- \
  apoci follow add "https://registry.frostlink.dev/ap/actor"

# OR: Frostlink follows Artemis
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow add "https://registry.dcunha.io/ap/actor"
```

### Step 2: Accept on the receiving side

```bash
# Check pending on Frostlink
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow pending

# Accept (use the actor/domain shown in pending output)
kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow accept dcunha.io
```

With `autoAccept: mutual`, one `accept` call federates both directions. When you accept the first
follow, apoci sends a follow-back to the requester. The requester already follows you, so it accepts
the follow-back automatically.

### Step 3: Verify

```bash
# Both should show the peer in their following list
kubectl --context artemis -n fediverse exec deploy/apoci -c app -- \
  apoci follow list

kubectl --context frostlink -n fediverse exec deploy/apoci -c app -- \
  apoci follow list

# Check outgoing request was accepted
kubectl --context artemis -n fediverse exec deploy/apoci -c app -- \
  apoci follow outgoing
```

## Other Useful Commands

Run these inside the pod. Prefix each one with
`kubectl --context <cluster> -n fediverse exec deploy/apoci -c app --`.

```bash
# View pending follow requests
apoci follow pending

# Reject a follow
apoci follow reject <domain>

# Unfollow a peer
apoci follow remove <domain>

# List known actors
apoci actor list

# Show this node's identity
apoci identity show
```

## Remote targeting (without exec)

All follow commands take `--remote` and `--token`, to target an instance from outside the pod. The
help text calls `--token` the "registry token for remote auth". The secret holds both
`APOCI_ADMIN_TOKEN` and `APOCI_REGISTRY_TOKEN`. Which of the two `--remote` accepts is not verified.
The same is true for the `APOCI_REMOTE_URL` and `APOCI_ADMIN_TOKEN` environment variables.

```bash
ARTEMIS_TOKEN=$(kubectl -n fediverse get secret apoci -o jsonpath='{.data.APOCI_ADMIN_TOKEN}' | base64 -d)

apoci follow add "https://registry.frostlink.dev/ap/actor" \
  --remote https://registry.dcunha.io \
  --token "$ARTEMIS_TOKEN"
```

## Garbage Collection & Retention

`gc.retention` is in `app/resources/config.yaml` of each cluster's apoci app. Both clusters use the
same shape: a global `keepLastN`, `pinnedGlobs`, and one `perRepo` rule for the cluster's own Flux
artifact. To read the current values, run
`grep -n -A20 'gc:' kube/clusters/*/apps/fediverse/apoci/app/resources/config.yaml`.

`main` must stay in `pinnedGlobs`. The FluxInstance and the `flux-system` OCIRepository both track
`oci://registry.dcunha.io/exikle/artemis:main`. Without an explicit pin, that tag is an ordinary
retention candidate. If retention deletes it, the whole cluster stops reconciling. Frostlink has the
same arrangement on `registry.frostlink.dev/exikle/frostlink:main`.

`maxAge` overrides `keepLastN`. It is not a floor. This was tested live on both clusters on
2026-08-05. With `keepLastN: 7, maxAge: 24h`, the surviving set is _(newest 7)_ ∩ _(newer than
24h)_. Artemis had more than 7 tags under 24h and kept 7. Frostlink had only 4 under 24h and kept 4. Do not assume that `keepLastN` protects anything older than `maxAge`.

The `perRepo` rule targets `dcunha.io/exikle/artemis`, the local Flux artifact repo. Flux tags it
once per commit and never reuses a tag, so it grows without limit. The rule reclaims little disk,
because these are manifest artifacts, not image layers. It is tag hygiene.

A `perRepo` key is the exact stored name, `<accountDomain>/<path>`, or the path relative to the
local `accountDomain`. Globs do not work there. A peer mirror is stored under the peer's domain, for
example `erwanleboucher.dev/eleboucher/piefed`.

Peer mirrors fill the disk, not our own images. On 2026-11-16, about 90% of the blob bytes on both
clusters belonged to repos mirrored from peers. Retention applies to peer mirrors too, so the global
`keepLastN` keeps them small. Do not pin version globs such as `v*` or `*.*.*` globally. Most peer
tags match them, and apoci never deletes a pinned tag. With those pins, Artemis kept every peer
version forever and stayed above 80% full.

`federation.excludedRepos` is outbound only. It stops this node from federating matching repos out.
It does not block the blobs of a peer from arriving. `diskUsageThreshold` only schedules an extra GC
cycle. It does not widen what a cycle deletes.

### Signatures and the untagged prune

The untagged prune deletes manifests that have no tag after `gc.untaggedManifestAge`. If the key is
unset, the age is 7 days, not off. Only a value of 0 or less turns the prune off, and then nothing
that retention untags is ever freed. The prune keeps a manifest that has referrers, but it does not
keep the referrers. A cosign signature is an untagged referrer. So apoci deletes each Flux artifact
signature 7 days after the push. Upstream has no option to keep them (home-infra #3311).

This is safe while each cluster pushes a new artifact at least once a week. Flux checks the
signature again only after a new push, or after source-controller restarts with empty storage. The
`apoci-signature-check` cronjob in each cluster's apoci app runs every hour. It looks up the
signature of `:main` on the local registry and on the peer's federated copy. The
`FluxArtifactSignatureMissing` alert fires after about 3 hours with no success. The expression trips
after 2 hours (`> 7200`), and `for: 1h` adds one more hour.

The upstream configuration reference is `configs/apoci.example.yaml` in `eleboucher/apoci`.

## Troubleshooting

Webfinger 404 on the bare domain: use the full actor URL (`https://registry.<domain>/ap/actor`), not
the domain shorthand. The domain-only form does a webfinger lookup on the bare domain, which does not
always resolve in-cluster.

Do not add a `queryParams` filter to the webfinger HTTPRoute. A common homelab pattern restricts the
route with `type: RegularExpression, value: ".*registry@.*"`. A manual `curl` test passes, because
curl does not encode `@`. Go's `net/http`, which apoci uses, encodes it as `%40`. The regex never
matches the encoded request, so every apoci-to-apoci federation call gets a 404. Match only the
path. apoci answers unknown resources with its own 404.

Follow stuck in `pending`: `autoAccept` is `mutual`, not `all`. The peer must accept explicitly,
unless it already follows you. On the receiving instance, run `apoci follow pending`, then
`apoci follow accept <domain>`.

Follow rejected: read the `autoAccept` setting on the remote. If it is `none`, the remote always
needs a manual accept.

Asymmetric state after data loss (one side shows a follower, the other does not): do not fix this
with `follow remove`. `remove` (and `remove --force`) clears both the outgoing and the incoming
follow on your side. It then sends an ActivityPub Unfollow to the remote, which removes you from the
follower list of the remote. You end up in an endless remove and re-add loop. Instead, run
`follow add <actor>` again on the side that is missing the follow. If the remote no longer records
the follow, it accepts the new Follow activity and updates its state.

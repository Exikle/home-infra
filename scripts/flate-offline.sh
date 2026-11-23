#!/usr/bin/env bash
# Prepare a COPY of the repo tree for an offline flate render of one cluster.
#
# flate 0.8.0 does not support ArtifactGenerator `artifacts[].namespace` or `copy[].optional`,
# which the per-app artifacts use (kube/base/flux-system/artifactgenerator.yaml).
# So this script does the generators' work by hand:
#   - builds kube/clusters/current/ the way the `base` generator does: each shared app from
#     kube/base/<ns>/<app>/, then the cluster's overlays/<ns>/<app>/ on top, plus the cluster's
#     components/;
#   - points every app Kustomization back at the whole tree (the flux-system OCIRepository).
# Remove the sourceRef rewrite once flate supports both fields. Never run it on a checkout you
# will commit from: it rewrites ks.yaml files and adds kube/clusters/current/ in place.
set -euo pipefail
tree="${1:?usage: flate-offline.sh <tree-root> <cluster>}"
cluster="${2:?usage: flate-offline.sh <tree-root> <cluster>}"
[[ -d "$tree/kube/clusters/$cluster" ]] || { echo "flate-offline: $tree has no kube/clusters/$cluster" >&2; exit 2; }

current="$tree/kube/clusters/current"
rm -rf "$current"
mkdir -p "$current/apps"
for app in "$tree"/kube/base/*/*/; do
    rel="${app#"$tree/kube/base/"}"
    mkdir -p "$current/apps/$rel"
    cp -r "$app". "$current/apps/$rel"
    rm -f "$current/apps/$rel/ks.yaml"
    overlay="$tree/kube/clusters/$cluster/overlays/$rel"
    if [[ -d "$overlay" ]]; then cp -r "$overlay". "$current/apps/$rel"; fi
done
cp -r "$tree/kube/clusters/$cluster/components" "$current/components"
# Flux only ever reads the combined copy; leaving the originals makes flate see every object twice.
rm -rf "$tree/kube/clusters/$cluster/overlays"

find "$tree/kube/base" "$tree/kube/clusters/$cluster/apps" -name ks.yaml -print0 \
    | xargs -0 -r grep -lZ '^    kind: ExternalArtifact$' \
    | xargs -0 -r sed -i -e '/^  sourceRef:$/,/^  [a-z]/{s/^    kind: ExternalArtifact$/    kind: OCIRepository/;s/^    name: .*$/    name: flux-system\n    namespace: flux-system/}'
# Nothing reads the generators now, and flate would still run them and fail.
rm -f "$tree/kube/base/flux-system/artifactgenerator.yaml"
sed -i '/artifactgenerator\.yaml$/d' "$tree/kube/base/flux-system/kustomization.yaml"

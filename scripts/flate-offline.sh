#!/usr/bin/env bash
# Prepare a COPY of the repo tree for an offline flate render of one cluster.
#
# flate 0.8.0 does not support ArtifactGenerator `artifacts[].namespace` or `copy[].optional`,
# which the per-app artifacts use (kube/base/flux-system/artifactgenerator.yaml).
# So this script points every app Kustomization back at the whole tree (the flux-system
# OCIRepository), where every path the generators copy already sits at its real place.
# Remove it once flate supports both fields. Never run it on a checkout you will commit from:
# it rewrites ks.yaml files in place.
set -euo pipefail
tree="${1:?usage: flate-offline.sh <tree-root> <cluster>}"
cluster="${2:?usage: flate-offline.sh <tree-root> <cluster>}"
[[ -d "$tree/kube/clusters/$cluster" ]] || { echo "flate-offline: $tree has no kube/clusters/$cluster" >&2; exit 2; }

find "$tree/kube/base" "$tree/kube/clusters/$cluster/apps" -name ks.yaml -print0 \
    | xargs -0 -r grep -lZ '^    kind: ExternalArtifact$' \
    | xargs -0 -r sed -i -e '/^  sourceRef:$/,/^  [a-z]/{s/^    kind: ExternalArtifact$/    kind: OCIRepository/;s/^    name: .*$/    name: flux-system\n    namespace: flux-system/}'
# Nothing reads the generators now, and flate would still run them and fail.
rm -f "$tree/kube/base/flux-system/artifactgenerator.yaml"
sed -i '/artifactgenerator\.yaml$/d' "$tree/kube/base/flux-system/kustomization.yaml"

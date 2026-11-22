#!/usr/bin/env bash
# Prepare a COPY of the repo tree for an offline flate render.
#
# flate 0.8.0 does not support ArtifactGenerator `artifacts[].namespace` or `copy[].optional`,
# which the per-app artifacts use (kube/clusters/<c>/apps/flux-system/artifactgenerator.yaml).
# Each artifact keeps repo paths, so pointing every app Kustomization back at the whole tree
# (the flux-system OCIRepository) renders the same objects. Remove this once flate supports both
# fields. Never run it on a checkout you will commit from: it rewrites ks.yaml files in place.
set -euo pipefail
tree="${1:?usage: flate-offline.sh <tree-root>}"
[[ -d "$tree/kube/clusters" ]] || { echo "flate-offline: $tree has no kube/clusters" >&2; exit 2; }
find "$tree/kube/clusters" -path '*/apps/*' -name ks.yaml -print0 \
    | xargs -0 -r grep -lZ '^    kind: ExternalArtifact$' \
    | xargs -0 -r sed -i -e '/^  sourceRef:$/,/^  [a-z]/{s/^    kind: ExternalArtifact$/    kind: OCIRepository/;s/^    name: .*$/    name: flux-system\n    namespace: flux-system/}'
# Nothing reads the generator now, and flate would still run it and fail.
find "$tree/kube/clusters" -path '*/apps/flux-system/artifactgenerator.yaml' -delete

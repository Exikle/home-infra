#!/bin/sh
# Fail when the artifact behind :main has no signature referrer, on any target.
set -u
fail=0
for t in ${TARGETS}; do
  base=${t%%|*}
  repo=${t#*|}
  digest=$(curl -sfI -m 20 -H 'Accept: application/vnd.oci.image.manifest.v1+json' "${base}/v2/${repo}/manifests/main" | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p')
  if [ -z "${digest}" ]; then
    echo "${base}/${repo}: cannot resolve main"
    fail=1
    continue
  fi
  if curl -sf -m 20 "${base}/v2/${repo}/referrers/${digest}" | grep -q '"manifests":\[{'; then
    echo "${base}/${repo}@${digest}: signed"
  else
    echo "${base}/${repo}@${digest}: no signature"
    fail=1
  fi
done
exit "${fail}"

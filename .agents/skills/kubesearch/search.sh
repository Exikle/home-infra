#!/usr/bin/env bash
set -euo pipefail

app="${1:-}"
if [[ -z "$app" ]]; then
    echo "usage: search.sh <app-name>" >&2
    exit 2
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

n=0
while curl -sfo "$dir/data-$n.json" "https://kubesearch.dev/hr/data-$n.json"; do
    n=$((n + 1))
done
rm -f "$dir/data-$n.json"

if [[ "$n" -eq 0 ]]; then
    echo "no kubesearch data chunks found" >&2
    exit 1
fi

python3 -I - "$app" "$dir" <<'PY' | sort -t'|' -k1 -rn | head -15
import glob, json, sys

app = sys.argv[1].lower()
for path in sorted(glob.glob(sys.argv[2] + "/data-*.json")):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        continue
    for v in data.values():
        if app in v.get("name", "").lower():
            best = sorted(v["repos"], key=lambda r: -r.get("stars", 0))
            for r in best[:3]:
                print(r.get("stars", 0), "|", v["name"], "|", r["repo"], "|", r["url"])
PY

#!/bin/sh
# Restart autobrr IRC networks that dropped with a connection error; fail if any stay unhealthy. See media-stack.md.
set -eu

api="http://autobrr.media.svc.cluster.local/api"

networks() {
    curl -fsS --max-time 30 -H "X-API-Token: ${AUTOBRR_WATCHDOG_API_KEY}" "${api}/irc"
}

# Read the list first: in "$(networks | jq ...)" a failed curl is hidden, jq exits 0 on empty input.
list=$(networks)
failed=$(printf '%s' "${list}" | jq -r '.[] | select(.enabled and (.healthy | not) and (.connection_errors | length > 0))
    | "\(.id)\t\(.name)\t\(.connection_errors | join("; "))"')

if [ -n "${failed}" ]; then
    printf '%s\n' "${failed}" | while IFS="$(printf '\t')" read -r id name errors; do
        echo "restarting ${name}: ${errors}"
        curl -fsS --max-time 30 -X POST -H "X-API-Token: ${AUTOBRR_WATCHDOG_API_KEY}" "${api}/irc/network/${id}/restart" >/dev/null
    done
    sleep 90
fi

list=$(networks)
unhealthy=$(printf '%s' "${list}" | jq -r '.[] | select(.enabled and (.healthy | not))
    | "\(.name) connected=\(.connected) errors=\(.connection_errors | join("; "))"')
if [ -z "${unhealthy}" ]; then
    echo "all enabled IRC networks healthy"
    exit 0
fi
echo "unhealthy:"
printf '%s\n' "${unhealthy}"
exit 1

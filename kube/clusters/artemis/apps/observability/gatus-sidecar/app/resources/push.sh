#!/bin/sh
# Every minute, send the newest result of every check to frostlink's status page.
while true; do
  curl -fsS --max-time 20 "http://127.0.0.1:${GATUS_WEB_PORT}/api/v1/endpoints/statuses?pageSize=1" |
    curl -fsS --max-time 20 -o /dev/null -X POST \
      -H "Authorization: Bearer ${HOME_PUSH_TOKEN}" \
      -H "Content-Type: application/json" \
      --data-binary @- "${PUSH_URL}" ||
    echo "push failed"
  sleep 60
done

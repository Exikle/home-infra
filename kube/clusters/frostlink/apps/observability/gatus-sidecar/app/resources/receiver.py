"""Receive check results pushed from home and feed them to the local Gatus."""

import hmac
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.environ["HOME_PUSH_TOKEN"]
GATUS = "http://127.0.0.1:" + os.environ.get("GATUS_WEB_PORT", "8080")
OUT = os.environ.get("OUTPUT", "/config/home.yaml")
HEARTBEAT = os.environ.get("HEARTBEAT_INTERVAL", "5m")
SAFE = re.compile(r"^[A-Za-z0-9 ._-]{1,64}$")
MAX_BODY = 1 << 20

forwarded = {}


def render(endpoints):
    lines = ["external-endpoints:"]
    for group, name in sorted(endpoints):
        lines += [
            f'  - name: "{name}"',
            f'    group: "{group}"',
            '    token: "${HOME_PUSH_TOKEN}"',
            "    heartbeat:",
            f"      interval: {HEARTBEAT}",
        ]
    return "\n".join(lines) + "\n"


def write_if_changed(text):
    try:
        with open(OUT) as f:
            if f.read() == text:
                return
    except FileNotFoundError:
        pass
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, OUT)
    print(f"wrote {OUT}", flush=True)


def forward(key, result):
    success = bool(result.get("success"))
    errors = result.get("errors") or [
        c.get("condition", "")
        for c in result.get("conditionResults") or []
        if not c.get("success")
    ]
    query = urllib.parse.urlencode(
        {
            "success": "true" if success else "false",
            "error": "; ".join(errors)[:500],
            "duration": f"{int(result.get('duration') or 0) / 1e9:.3f}s",
        }
    )
    req = urllib.request.Request(
        f"{GATUS}/api/v1/endpoints/{urllib.parse.quote(key)}/external?{query}",
        method="POST",
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    try:
        urllib.request.urlopen(req, timeout=10).close()
        return True
    except urllib.error.URLError as e:
        print(f"forward {key}: {e}", flush=True)
        return False


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if not hmac.compare_digest(auth, f"Bearer {TOKEN}"):
            return self.send_error(401)
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY:
            return self.send_error(413)
        try:
            statuses = json.loads(self.rfile.read(length))
        except ValueError:
            return self.send_error(400)

        endpoints = set()
        results = []
        for s in statuses if isinstance(statuses, list) else []:
            group, name, key = s.get("group") or "", s.get("name") or "", s.get("key") or ""
            if not (SAFE.match(group) and SAFE.match(name) and SAFE.match(key)):
                continue
            endpoints.add((group, name))
            if s.get("results"):
                results.append((key, s["results"][-1]))
        if not endpoints:
            return self.send_error(400)

        write_if_changed(render(endpoints))
        for key, result in results:
            stamp = result.get("timestamp")
            if forwarded.get(key) != stamp and forward(key, result):
                forwarded[key] = stamp

        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer(("", int(os.environ.get("PORT", "8081"))), Handler).serve_forever()

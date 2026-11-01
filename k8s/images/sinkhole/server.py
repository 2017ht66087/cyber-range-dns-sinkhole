#!/usr/bin/env python3
"""
sinkhole: HTTP capture endpoint + live dashboard on :8080.

  GET  /            -> HTML dashboard (auto-refreshing) of captured events
  GET  /api/captures-> JSON list of captures
  POST /capture     -> record a capture (firewall-sim posts here on intercept)
  any other request -> treated as a beacon hit, recorded, answered "sinkholed"

Everything is also logged to stdout (kubectl logs deploy/sinkhole).
"""
import json
import threading
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8080
CAPTURES = deque(maxlen=500)
LOCK = threading.Lock()


def ts():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def _record(self, body):
        rec = {"time": ts()}
        rec.update(body)
        with LOCK:
            CAPTURES.append(rec)

    def do_GET(self):
        if self.path.startswith("/api/captures"):
            with LOCK:
                data = list(CAPTURES)
            self._send(200, "application/json", json.dumps(data))
            return
        if self.path in ("/", "/dashboard"):
            self._send(200, "text/html; charset=utf-8", self._dashboard())
            return
        # any other GET = a beacon that reached the sinkhole
        self._record({"event": "http-callback", "path": self.path,
                      "client": self.client_address[0]})
        print(f"[sinkhole] {ts()} CAPTURE GET {self.path} from {self.client_address[0]}", flush=True)
        self._send(200, "application/json", '{"status":"sinkholed"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode() or "{}")
        except Exception:
            body = {"raw": raw.decode(errors="replace")}
        body.setdefault("client", self.client_address[0])
        self._record(body)
        print(f"[sinkhole] {ts()} CAPTURE POST {self.path} from {self.client_address[0]} body={body}", flush=True)
        self._send(200, "application/json", '{"status":"sinkholed"}')

    def do_DELETE(self):
        if self.path.startswith("/api/captures"):
            with LOCK:
                n = len(CAPTURES)
                CAPTURES.clear()
            print(f"[sinkhole] {ts()} cleared {n} captures", flush=True)
            self._send(200, "application/json", json.dumps({"cleared": n}))
            return
        self._send(404, "application/json", '{"error":"not found"}')

    def _dashboard(self):
        with LOCK:
            data = list(CAPTURES)[::-1]
        rows = "".join(
            "<tr><td>{time}</td><td>{domain}</td><td>{client}</td>"
            "<td>{sink}</td><td>{event}</td></tr>".format(
                time=c.get("time", ""),
                domain=c.get("domain", "-"),
                client=c.get("client", "-"),
                sink=c.get("sinkhole_ip", "-"),
                event=c.get("event", "-"),
            )
            for c in data[:200]
        )
        empty = ("<tr><td colspan=5 class=k>No captures yet - switch to the "
                 "sinkhole-ON variant and wait for a beacon.</td></tr>")
        return """<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="3"><title>DNS Sinkhole - Captures</title>
<style>
body{{font-family:system-ui,Segoe UI,Arial;margin:2rem;background:#0b1021;color:#e6e6e6}}
h1{{color:#5cd6ff;margin:0 0 .25rem}}
.k{{color:#9aa4b2}} .n{{font-size:2rem;font-weight:700;color:#7cf29a}}
table{{border-collapse:collapse;width:100%;margin-top:1rem}}
th,td{{border-bottom:1px solid #263042;padding:.5rem .75rem;text-align:left;font-size:.9rem}}
th{{color:#5cd6ff;text-transform:uppercase;font-size:.72rem;letter-spacing:.05em}}
tr:hover td{{background:#141b33}}
</style></head><body>
<h1>DNS Sinkhole &mdash; Capture Dashboard</h1>
<div class="k">Total captures: <span class="n">{count}</span> &nbsp;|&nbsp; auto-refresh 3s &nbsp;|&nbsp; {now}</div>
<table><thead><tr><th>Time (UTC)</th><th>Domain</th><th>Client</th><th>Sinkhole IP</th><th>Event</th></tr></thead>
<tbody>{rows}</tbody></table>
</body></html>""".format(count=len(data), now=ts(), rows=(rows or empty))

    def log_message(self, *args):
        pass


def main():
    print(f"[sinkhole] listening on :{PORT} (dashboard at /)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()

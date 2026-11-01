#!/usr/bin/env python3
"""
fake-internet: INetSim-style simulated internet for the range (stdlib only).

Three listeners in one process:
  :8080  fake web   - answers ANY host / path / method with a generic page and
                      logs it (host, method, path, client, user-agent, time).
                      external-dns points benign public names here.
  :8066  fake C2    - the "attacker" server. Any request is a check-in: it is
                      recorded (implant, domain, client, time) and answered with
                      a harmless fake tasking payload.
  :8081  dashboard  - GET /                 live HTML view
                      GET /api/requests     web requests (JSON)
                      GET /api/checkins     C2 check-ins (JSON)
                      DELETE /api/requests | /api/checkins | /api/all  clear

Nothing here ever makes an outbound connection.
"""
import html
import json
import os
import secrets
import threading
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WEB_PORT = int(os.getenv("WEB_PORT", "8080"))
C2_PORT = int(os.getenv("C2_PORT", "8066"))
DASH_PORT = int(os.getenv("DASH_PORT", "8081"))

REQUESTS = deque(maxlen=500)
CHECKINS = deque(maxlen=500)
LOCK = threading.Lock()


def ts():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"[fake-internet] {ts()} {msg}", flush=True)


class Base(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""

    def log_message(self, *args):
        pass

    def _send(self, code, ctype, body):
        payload = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _body(self):
        n = min(int(self.headers.get("Content-Length", 0) or 0), 64 * 1024)
        return self.rfile.read(n) if n else b""

    def _host(self):
        return (self.headers.get("Host") or "-").split(":")[0][:253]


class WebHandler(Base):
    """Catch-all web server: every host resolves to us, every path exists."""

    def _handle(self):
        self._body()
        rec = {"time": ts(), "kind": "web", "host": self._host(), "method": self.command,
               "path": self.path[:300], "client": self.client_address[0],
               "user_agent": (self.headers.get("User-Agent") or "")[:200]}
        with LOCK:
            REQUESTS.append(rec)
        log(f"WEB {rec['method']} http://{rec['host']}{rec['path']} from {rec['client']}")
        page = ("<!doctype html><html><head><title>{h}</title></head><body>"
                "<h1>{h}</h1><p>Simulated internet (cyber range). No real site was contacted.</p>"
                "</body></html>").format(h=html.escape(rec["host"]))
        self._send(200, "text/html; charset=utf-8", page)

    do_GET = do_POST = do_PUT = do_HEAD = do_DELETE = do_OPTIONS = _handle


class C2Handler(Base):
    """Fake attacker C2: records check-ins and returns a fake (inert) tasking."""

    def _handle(self):
        raw = self._body()
        try:
            body = json.loads(raw.decode() or "{}")
            if not isinstance(body, dict):
                body = {"data": body}
        except ValueError:
            body = {"raw": raw.decode(errors="replace")[:500]}
        task = {"task_id": secrets.token_hex(4), "command": "sleep", "args": {"seconds": 60},
                "note": "FAKE TASKING - cyber range simulation, no real C2"}
        rec = {"time": ts(), "kind": "c2-checkin", "host": self._host(), "method": self.command,
               "path": self.path[:300], "client": self.client_address[0],
               "implant": str(body.get("implant", "-"))[:100],
               "domain": str(body.get("domain", self._host()))[:253],
               "task_id": task["task_id"]}
        with LOCK:
            CHECKINS.append(rec)
        log(f"C2 CHECK-IN implant={rec['implant']} domain={rec['domain']} from {rec['client']} "
            f"{rec['method']} {rec['path']} -> task {task['task_id']} ({task['command']})")
        self._send(200, "application/json", json.dumps(task))

    do_GET = do_POST = do_PUT = do_HEAD = _handle


class DashHandler(Base):
    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, "application/json", '{"ok": true}')
        with LOCK:
            reqs, chks = list(REQUESTS), list(CHECKINS)
        if self.path.startswith("/api/requests"):
            return self._send(200, "application/json", json.dumps(reqs))
        if self.path.startswith("/api/checkins"):
            return self._send(200, "application/json", json.dumps(chks))
        if self.path in ("/", "/dashboard"):
            return self._send(200, "text/html; charset=utf-8", dashboard(reqs, chks))
        self._send(404, "application/json", '{"error": "not found"}')

    def do_DELETE(self):
        targets = {"/api/requests": [REQUESTS], "/api/checkins": [CHECKINS],
                   "/api/all": [REQUESTS, CHECKINS]}.get(self.path)
        if targets is None:
            return self._send(404, "application/json", '{"error": "not found"}')
        with LOCK:
            n = sum(len(t) for t in targets)
            for t in targets:
                t.clear()
        log(f"cleared {n} records ({self.path})")
        self._send(200, "application/json", json.dumps({"cleared": n}))


def dashboard(reqs, chks):
    e = html.escape
    c_rows = "".join(
        f"<tr><td>{e(c['time'])}</td><td>{e(c['implant'])}</td><td>{e(c['domain'])}</td>"
        f"<td>{e(c['client'])}</td><td>{e(c['task_id'])}</td></tr>" for c in chks[::-1][:100]
    ) or "<tr><td colspan=5 class=k>No C2 check-ins (sinkhole ON keeps the implant away).</td></tr>"
    r_rows = "".join(
        f"<tr><td>{e(r['time'])}</td><td>{e(r['host'])}</td><td>{e(r['method'])} {e(r['path'])}</td>"
        f"<td>{e(r['client'])}</td></tr>" for r in reqs[::-1][:100]
    ) or "<tr><td colspan=4 class=k>No web requests yet.</td></tr>"
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="5"><title>Fake Internet - Activity</title>
<style>
body{{font-family:system-ui,Segoe UI,Arial;margin:2rem;background:#0b1021;color:#e6e6e6}}
h1{{color:#5cd6ff;margin:0 0 .25rem}} h2{{color:#ff9f5c;margin-top:1.5rem}}
.k{{color:#9aa4b2}} .n{{font-size:1.6rem;font-weight:700;color:#7cf29a}}
table{{border-collapse:collapse;width:100%;margin-top:.5rem}}
th,td{{border-bottom:1px solid #263042;padding:.45rem .7rem;text-align:left;font-size:.88rem}}
th{{color:#5cd6ff;text-transform:uppercase;font-size:.72rem;letter-spacing:.05em}}
</style></head><body>
<h1>Fake Internet &mdash; Activity</h1>
<div class="k">C2 check-ins: <span class="n">{len(chks)}</span> &nbsp;|&nbsp;
web requests: <span class="n">{len(reqs)}</span> &nbsp;|&nbsp; auto-refresh 5s &nbsp;|&nbsp; {ts()}</div>
<h2>Fake attacker C2 check-ins</h2>
<table><thead><tr><th>Time (UTC)</th><th>Implant</th><th>Domain</th><th>Client</th><th>Task</th></tr></thead>
<tbody>{c_rows}</tbody></table>
<h2>Web requests (any host)</h2>
<table><thead><tr><th>Time (UTC)</th><th>Host</th><th>Request</th><th>Client</th></tr></thead>
<tbody>{r_rows}</tbody></table>
</body></html>"""


def serve(port, handler):
    ThreadingHTTPServer(("0.0.0.0", port), handler).serve_forever()


def main():
    log(f"web :{WEB_PORT}  c2 :{C2_PORT}  dashboard :{DASH_PORT}")
    threading.Thread(target=serve, args=(WEB_PORT, WebHandler), daemon=True).start()
    threading.Thread(target=serve, args=(C2_PORT, C2Handler), daemon=True).start()
    serve(DASH_PORT, DashHandler)


if __name__ == "__main__":
    main()

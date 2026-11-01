#!/usr/bin/env python3
"""
web02: thin corp "HR portal" (stdlib only) - the app tier of a 3-tier flow.

  browser -> web01 (nginx, /app/) -> web02 :8080 -> db01 (PostgreSQL, hr.employees)
                                               +-> db02 (MariaDB,   crm.customers)

Queries go through the psql / mariadb CLI clients so no Python DB driver is
needed. Credentials come from env (Kubernetes Secret), never from the image.
"""
import html
import json
import os
import subprocess
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.getenv("PORT", "8080"))
DB01 = dict(host=os.getenv("DB01_HOST", "db01.corp.svc.cluster.local"),
            db=os.getenv("DB01_NAME", "corp"), user=os.getenv("DB01_USER", "web_ro"),
            pw=os.getenv("DB01_PASSWORD", ""))
DB02 = dict(host=os.getenv("DB02_HOST", "db02.corp.svc.cluster.local"),
            db=os.getenv("DB02_NAME", "crm"), user=os.getenv("DB02_USER", "web_ro"),
            pw=os.getenv("DB02_PASSWORD", ""))


def log(msg):
    print(f"[corp-web02] {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}", flush=True)


def _rows(cmd, env):
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=10)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[:300] or f"exit {p.returncode}")
    return [line.split("\t") for line in p.stdout.splitlines() if line.strip()]


def employees():
    env = dict(os.environ, PGPASSWORD=DB01["pw"], PGCONNECT_TIMEOUT="5")
    return _rows(["psql", "-h", DB01["host"], "-U", DB01["user"], "-d", DB01["db"], "-At", "-F", "\t",
                  "-c", "SELECT emp_id, full_name, department, title, ad_account FROM hr.employees ORDER BY emp_id"],
                 env)


def customers():
    env = dict(os.environ, MYSQL_PWD=DB02["pw"])
    return _rows(["mariadb", "-h", DB02["host"], "-u", DB02["user"], "-D", DB02["db"], "-B", "-N",
                  "--connect-timeout=5", "--skip-ssl",
                  "-e", "SELECT id, company, contact, country, tier FROM customers ORDER BY id"], env)


def _table(headers, rows):
    head = "".join(f"<th>{html.escape(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{html.escape(c)}</td>" for c in r) + "</tr>" for r in rows)
    return f"<table><tr>{head}</tr>{body}</table>"


def section(title, src, fn, headers):
    try:
        rows = fn()
        return f"<h2>{title}</h2><p class=src>source: {src} ({len(rows)} rows)</p>" + _table(headers, rows)
    except Exception as e:
        return f"<h2>{title}</h2><p class=err>{html.escape(src)} unavailable: {html.escape(str(e))}</p>"


PAGE = """<!doctype html><html><head><meta charset=utf-8><title>CORP HR portal (web02)</title>
<style>body{{font-family:sans-serif;margin:2em;background:#f6f7f9}}table{{border-collapse:collapse;background:#fff}}
td,th{{border:1px solid #ccc;padding:4px 10px}}th{{background:#2d4a7a;color:#fff}}.src{{color:#666}}.err{{color:#b00}}</style>
</head><body><h1>CORP HR portal</h1><p>web02 &middot; app tier of the corp.lab 3-tier demo</p>{body}</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/healthz":
            return self._send(200, "ok\n", "text/plain")
        if path == "/api/employees":
            try:
                rows = employees()
            except Exception as e:
                return self._send(502, json.dumps({"error": str(e)}), "application/json")
            keys = ["emp_id", "full_name", "department", "title", "ad_account"]
            return self._send(200, json.dumps([dict(zip(keys, r)) for r in rows]), "application/json")
        if path == "/":
            body = (section("Employees", f"db01 PostgreSQL {DB01['host']}", employees,
                            ["ID", "Name", "Department", "Title", "AD account"]) +
                    section("Customers", f"db02 MariaDB {DB02['host']}", customers,
                            ["ID", "Company", "Contact", "Country", "Tier"]))
            return self._send(200, PAGE.format(body=body))
        self._send(404, "not found\n", "text/plain")

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")


if __name__ == "__main__":
    log(f"listening on :{PORT} (db01={DB01['host']}, db02={DB02['host']})")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

#!/usr/bin/env python3
"""Benign mock C2 for the cyber range (ATK-C2).

NOT malware. It only records that a beacon reached it and returns a static OK.
It never issues commands, never returns payloads, never persists on clients.
Used so the "sinkhole OFF" path has something for the endpoint to talk to and
for the SOC to observe.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import datetime
import sys


class Handler(BaseHTTPRequestHandler):
    def _log(self, method):
        ts = datetime.datetime.utcnow().isoformat()
        print(f"{ts}Z {self.client_address[0]} {method} {self.path}", flush=True)

    def do_GET(self):
        self._log("GET")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        self.rfile.read(length)
        self._log(f"POST[{length}b]")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ACK")

    def log_message(self, *args):
        pass  # we do our own single-line logging


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    print(f"[mock-c2] benign listener on :{port}", flush=True)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()

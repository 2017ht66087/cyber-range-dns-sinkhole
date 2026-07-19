#!/usr/bin/env python3
"""
firewall-sim: DNS policy engine on :8053 (the "firewall / DNS gateway").

This is the component the ConfigMap toggles. For every query from the infected
host it decides:

  * MALICIOUS domain + SINKHOLE_ENABLED=true
        -> answer with SINKHOLE_IP, log the interception, and notify the
           sinkhole server (capture). The beacon is contained.
  * MALICIOUS domain + SINKHOLE_ENABLED=false
        -> forward to EXTERNAL_DNS (attacker-aware) and return the real
           attacker IP. Raise an ALERT. The beacon would escape (uncontained).
  * BENIGN domain
        -> forward to INTERNAL_DNS and return its answer.
  * anything else
        -> forward to EXTERNAL_DNS (public resolver).

Behavior is driven entirely by environment variables (ConfigMap-backed), so the
same image serves both range variants.
"""
import os
import json
import time
import socket
import threading
import urllib.request

from dnslib import RR, QTYPE, A, RCODE, DNSRecord
from dnslib.server import DNSServer, BaseResolver


def env_bool(name, default=False):
    return os.getenv(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


SINKHOLE_ENABLED = env_bool("SINKHOLE_ENABLED", False)
SINKHOLE_IP      = os.getenv("SINKHOLE_IP", "10.255.255.10")
MALICIOUS_DOMAIN = os.getenv("MALICIOUS_DOMAIN", "teq.xyz.com").rstrip(".").lower()
ALT_DOMAIN       = os.getenv("ALT_DOMAIN", "abc.com").rstrip(".").lower()
INTERNAL_DNS     = os.getenv("INTERNAL_DNS", "internal-dns.dns-system.svc.cluster.local")
EXTERNAL_DNS     = os.getenv("EXTERNAL_DNS", "external-dns.dns-system.svc.cluster.local")
SINKHOLE_URL     = os.getenv("SINKHOLE_URL", "http://sinkhole.cyber-range.svc.cluster.local:8080/capture")
PORT             = int(os.getenv("FIREWALL_PORT", "8053"))


def log(msg):
    print(f"[firewall-sim] {msg}", flush=True)


def _matches(qname, domain):
    return qname == domain or qname.endswith("." + domain)


def _upstream_ip(host):
    """Resolve an upstream DNS *service name* to a cluster IP via CoreDNS."""
    return socket.gethostbyname(host)


def _forward(qname, qtype, upstream_host):
    ip = _upstream_ip(upstream_host)
    # qtype is already a QTYPE *name* (e.g. "A"); DNSRecord.question wants the name.
    q = DNSRecord.question(qname, qtype)
    data = q.send(ip, 53, tcp=False, timeout=3)
    return DNSRecord.parse(data)


def _notify_sinkhole(qname, client):
    """Fire-and-forget capture notification. Runs in a background thread so it
    NEVER delays the DNS reply (a slow/blocked capture must not stall DNS)."""
    payload = json.dumps({
        "event": "dns-intercept",
        "domain": qname,
        "client": client,
        "sinkhole_ip": SINKHOLE_IP,
        "ts": time.time(),
    }).encode()

    def _send():
        try:
            req = urllib.request.Request(SINKHOLE_URL, data=payload,
                                         headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=3).read()
        except Exception as e:  # best-effort; never break DNS on notify failure
            log(f"sinkhole notify failed: {e}")

    threading.Thread(target=_send, daemon=True).start()


class FirewallResolver(BaseResolver):
    def resolve(self, request, handler):
        reply = request.reply()
        qname = str(request.q.qname).rstrip(".").lower()
        qtype = QTYPE[request.q.qtype]
        client = handler.client_address[0] if handler and handler.client_address else "?"

        is_malicious = _matches(qname, MALICIOUS_DOMAIN)
        is_benign    = _matches(qname, ALT_DOMAIN)

        # --- malicious + sinkhole ON: intercept ---
        if is_malicious and SINKHOLE_ENABLED:
            reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(SINKHOLE_IP), ttl=5))
            log(f"[SINKHOLE] intercepted {qname} from {client} -> {SINKHOLE_IP} (contained)")
            _notify_sinkhole(qname, client)
            return reply

        # --- everything else: forward to the right upstream ---
        upstream = INTERNAL_DNS if is_benign else EXTERNAL_DNS
        try:
            ans = _forward(qname, qtype, upstream)
            for rr in ans.rr:
                reply.add_answer(rr)
            reply.header.rcode = ans.header.rcode
            answers = ", ".join(str(rr.rdata) for rr in ans.rr) or "(none)"
            if is_malicious and not SINKHOLE_ENABLED:
                log(f"[ALERT] malicious {qname} from {client} forwarded via EXTERNAL "
                    f"-> {answers}  (NO sinkhole; beacon would reach attacker)")
            else:
                tag = "benign" if is_benign else "public"
                log(f"[FORWARD] {qname} from {client} via {upstream.split('.')[0]} "
                    f"({tag}) -> {answers}")
        except Exception as e:
            reply.header.rcode = RCODE.SERVFAIL
            log(f"[SERVFAIL] {qname} upstream={upstream} error={e}")
        return reply


def main():
    mode = "ON (contained)" if SINKHOLE_ENABLED else "OFF (uncontained)"
    log(f"starting on :{PORT}  SINKHOLE={mode}  malicious={MALICIOUS_DOMAIN}")
    resolver = FirewallResolver()
    udp = DNSServer(resolver, port=PORT, address="0.0.0.0")
    tcp = DNSServer(resolver, port=PORT, address="0.0.0.0", tcp=True)
    udp.start_thread()
    tcp.start_thread()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()

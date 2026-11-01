#!/usr/bin/env python3
"""
external-dns: simulated PUBLIC / attacker-aware resolver.

Role in the range: this is the "outside world" resolver. It knows the malicious
C2 domain and resolves it to the attacker IP. When the firewall is NOT in
sinkhole mode, malicious lookups are forwarded here and succeed -> this is the
"what goes wrong" path (the infected host learns the real attacker address).
"""
import os
import time

from dnslib import RR, QTYPE, A, RCODE
from dnslib.server import DNSServer, BaseResolver

MALICIOUS_DOMAINS = [d.strip().rstrip(".").lower()
                     for d in os.getenv("MALICIOUS_DOMAIN", "teq.xyz.com").split(",") if d.strip()]
ATTACKER_IP       = os.getenv("ATTACKER_IP", "203.0.113.66")   # TEST-NET-3 (fake)
ALT_DOMAIN        = os.getenv("ALT_DOMAIN", "abc.com").rstrip(".").lower()
BENIGN_PUBLIC_IP  = os.getenv("BENIGN_PUBLIC_IP", "93.184.216.34")
DEFAULT_PUBLIC_IP = os.getenv("DEFAULT_PUBLIC_IP", "198.51.100.10")  # TEST-NET-2
# In-cluster fake internet (fake-internet namespace). When set, these are the
# addresses actually returned: the C2 domains -> fake C2, everything else ->
# fake web server. ATTACKER_IP stays the "real-world" attacker label in logs.
FAKE_C2_IP        = os.getenv("FAKE_C2_IP", "").strip()
FAKE_WEB_IP       = os.getenv("FAKE_WEB_IP", "").strip()
PORT              = int(os.getenv("DNS_PORT", "53"))


def log(msg):
    print(f"[external-dns] {msg}", flush=True)


def _matches(qname, domain):
    return qname == domain or qname.endswith("." + domain)


class ExternalResolver(BaseResolver):
    def resolve(self, request, handler):
        reply = request.reply()
        qname = str(request.q.qname).rstrip(".").lower()

        if any(_matches(qname, d) for d in MALICIOUS_DOMAINS):
            ip = FAKE_C2_IP or ATTACKER_IP
            note = f"ATTACKER C2 {ATTACKER_IP}, served by fake-internet" if FAKE_C2_IP else "ATTACKER C2"
        elif _matches(qname, ALT_DOMAIN):
            ip, note = FAKE_WEB_IP or BENIGN_PUBLIC_IP, "benign public"
        else:
            ip, note = FAKE_WEB_IP or DEFAULT_PUBLIC_IP, "generic public"
        reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(ip), ttl=30))
        log(f"resolve {qname} -> {ip} ({note})")
        return reply


def main():
    log(f"starting on :{PORT} (malicious={','.join(MALICIOUS_DOMAINS)}->{FAKE_C2_IP or ATTACKER_IP}, "
        f"public->{FAKE_WEB_IP or DEFAULT_PUBLIC_IP})")
    resolver = ExternalResolver()
    udp = DNSServer(resolver, port=PORT, address="0.0.0.0")
    tcp = DNSServer(resolver, port=PORT, address="0.0.0.0", tcp=True)
    udp.start_thread()
    tcp.start_thread()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()

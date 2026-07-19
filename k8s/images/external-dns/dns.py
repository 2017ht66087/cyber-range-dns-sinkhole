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

MALICIOUS_DOMAIN  = os.getenv("MALICIOUS_DOMAIN", "teq.xyz.com").rstrip(".").lower()
ATTACKER_IP       = os.getenv("ATTACKER_IP", "203.0.113.66")   # TEST-NET-3 (fake)
ALT_DOMAIN        = os.getenv("ALT_DOMAIN", "abc.com").rstrip(".").lower()
BENIGN_PUBLIC_IP  = os.getenv("BENIGN_PUBLIC_IP", "93.184.216.34")
DEFAULT_PUBLIC_IP = os.getenv("DEFAULT_PUBLIC_IP", "198.51.100.10")  # TEST-NET-2
PORT              = int(os.getenv("DNS_PORT", "53"))


def log(msg):
    print(f"[external-dns] {msg}", flush=True)


def _matches(qname, domain):
    return qname == domain or qname.endswith("." + domain)


class ExternalResolver(BaseResolver):
    def resolve(self, request, handler):
        reply = request.reply()
        qname = str(request.q.qname).rstrip(".").lower()

        if _matches(qname, MALICIOUS_DOMAIN):
            reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(ATTACKER_IP), ttl=30))
            log(f"resolve {qname} -> {ATTACKER_IP} (ATTACKER C2)")
        elif _matches(qname, ALT_DOMAIN):
            reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(BENIGN_PUBLIC_IP), ttl=30))
            log(f"resolve {qname} -> {BENIGN_PUBLIC_IP} (benign public)")
        else:
            reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(DEFAULT_PUBLIC_IP), ttl=30))
            log(f"resolve {qname} -> {DEFAULT_PUBLIC_IP} (generic public)")
        return reply


def main():
    log(f"starting on :{PORT} (malicious={MALICIOUS_DOMAIN}->{ATTACKER_IP})")
    resolver = ExternalResolver()
    udp = DNSServer(resolver, port=PORT, address="0.0.0.0")
    tcp = DNSServer(resolver, port=PORT, address="0.0.0.0", tcp=True)
    udp.start_thread()
    tcp.start_thread()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()

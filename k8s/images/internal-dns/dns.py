#!/usr/bin/env python3
"""
internal-dns: authoritative resolver for BENIGN / corporate domains.

Role in the range: this is the "internal" resolver the firewall forwards
legitimate lookups to. It knows the benign domain (ALT_DOMAIN) and refuses to
resolve the malicious C2 domain (an internal resolver would not know attacker
infrastructure).
"""
import os
import time

from dnslib import RR, QTYPE, A, RCODE
from dnslib.server import DNSServer, BaseResolver

ALT_DOMAIN       = os.getenv("ALT_DOMAIN", "abc.com").rstrip(".").lower()
BENIGN_IP        = os.getenv("BENIGN_IP", "10.0.0.50")
MALICIOUS_DOMAIN = os.getenv("MALICIOUS_DOMAIN", "teq.xyz.com").rstrip(".").lower()
PORT             = int(os.getenv("DNS_PORT", "53"))


def log(msg):
    print(f"[internal-dns] {msg}", flush=True)


def _matches(qname, domain):
    return qname == domain or qname.endswith("." + domain)


class InternalResolver(BaseResolver):
    def resolve(self, request, handler):
        reply = request.reply()
        qname = str(request.q.qname).rstrip(".").lower()

        if _matches(qname, ALT_DOMAIN):
            reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(BENIGN_IP), ttl=30))
            log(f"resolve {qname} -> {BENIGN_IP} (benign)")
        elif _matches(qname, MALICIOUS_DOMAIN):
            reply.header.rcode = RCODE.REFUSED
            log(f"REFUSED {qname} (malicious domain not served internally)")
        else:
            reply.header.rcode = RCODE.NXDOMAIN
            log(f"NXDOMAIN {qname} (unknown internally)")
        return reply


def main():
    log(f"starting on :{PORT} (benign={ALT_DOMAIN}->{BENIGN_IP})")
    resolver = InternalResolver()
    udp = DNSServer(resolver, port=PORT, address="0.0.0.0")
    tcp = DNSServer(resolver, port=PORT, address="0.0.0.0", tcp=True)
    udp.start_thread()
    tcp.start_thread()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()

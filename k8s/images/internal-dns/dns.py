#!/usr/bin/env python3
"""
internal-dns: authoritative resolver for BENIGN / corporate domains.

Role in the range: this is the "internal" resolver the firewall forwards
legitimate lookups to. It knows the benign domain (ALT_DOMAIN) and refuses to
resolve the malicious C2 domain (an internal resolver would not know attacker
infrastructure).
"""
import os
import socket
import time

from dnslib import RR, QTYPE, A, RCODE
from dnslib.server import DNSServer, BaseResolver

ALT_DOMAIN       = os.getenv("ALT_DOMAIN", "abc.com").rstrip(".").lower()
BENIGN_IP        = os.getenv("BENIGN_IP", "10.0.0.50")
MALICIOUS_DOMAINS = [d.strip().rstrip(".").lower()
                     for d in os.getenv("MALICIOUS_DOMAIN", "teq.xyz.com").split(",") if d.strip()]
PORT             = int(os.getenv("DNS_PORT", "53"))
# corp lab zone: <host>.corp.lab -> ClusterIP of Service <host> in namespace corp
# (manifests/corp-servers.yaml); the bare zone name points at the primary DC.
CORP_ZONE        = os.getenv("CORP_ZONE", "corp.lab").rstrip(".").lower()
CORP_NAMESPACE   = os.getenv("CORP_NAMESPACE", "corp")
CORP_APEX_HOST   = os.getenv("CORP_APEX_HOST", "dc01")


def log(msg):
    print(f"[internal-dns] {msg}", flush=True)


def _matches(qname, domain):
    return qname == domain or qname.endswith("." + domain)


def corp_lookup(qname):
    """IPv4 of a corp.lab host via its Kubernetes Service, or None."""
    host = CORP_APEX_HOST if qname == CORP_ZONE else qname[: -len(CORP_ZONE) - 1]
    if not host or "." in host:
        return None
    try:
        return socket.gethostbyname(f"{host}.{CORP_NAMESPACE}.svc.cluster.local.")
    except OSError:
        return None


class InternalResolver(BaseResolver):
    def resolve(self, request, handler):
        reply = request.reply()
        qname = str(request.q.qname).rstrip(".").lower()

        if _matches(qname, ALT_DOMAIN):
            reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(BENIGN_IP), ttl=30))
            log(f"resolve {qname} -> {BENIGN_IP} (benign)")
        elif CORP_ZONE and _matches(qname, CORP_ZONE):
            ip = corp_lookup(qname)
            if ip is None:
                reply.header.rcode = RCODE.NXDOMAIN
                log(f"NXDOMAIN {qname} (no such corp host)")
            elif request.q.qtype in (QTYPE.A, QTYPE.ANY):
                reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(ip), ttl=30))
                log(f"resolve {qname} -> {ip} (corp)")
        elif any(_matches(qname, d) for d in MALICIOUS_DOMAINS):
            reply.header.rcode = RCODE.REFUSED
            log(f"REFUSED {qname} (malicious domain not served internally)")
        else:
            reply.header.rcode = RCODE.NXDOMAIN
            log(f"NXDOMAIN {qname} (unknown internally)")
        return reply


def main():
    log(f"starting on :{PORT} (benign={ALT_DOMAIN}->{BENIGN_IP}, corp zone={CORP_ZONE})")
    resolver = InternalResolver()
    udp = DNSServer(resolver, port=PORT, address="0.0.0.0")
    tcp = DNSServer(resolver, port=PORT, address="0.0.0.0", tcp=True)
    udp.start_thread()
    tcp.start_thread()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()

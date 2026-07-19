#!/usr/bin/env python3
"""
infected-pc: the simulated compromised endpoint.

On a loop it behaves like malware beaconing to its C2:
  1. Ask the firewall (DNS_SERVER:8053) to resolve the malicious C2 domain.
  2. Inspect the answer:
       - SINKHOLE_IP  -> the firewall sinkholed us; beacon is CONTAINED.
       - attacker IP  -> resolution succeeded; beacon is UNCONTAINED.
  3. Attempt the C2 callback to the resolved IP (fails in-lab by design; the
     point is the resolution outcome + the sinkhole/firewall logs).

All behavior is read from the ConfigMap-backed environment.
"""
import os
import time
import socket

from dnslib import DNSRecord, QTYPE, RCODE

DNS_SERVER       = os.getenv("DNS_SERVER", "firewall-sim.cyber-range.svc.cluster.local")
DNS_PORT         = int(os.getenv("DNS_SERVER_PORT", "8053"))
MALICIOUS_DOMAIN = os.getenv("MALICIOUS_DOMAIN", "teq.xyz.com").rstrip(".").lower()
ALT_DOMAIN       = os.getenv("ALT_DOMAIN", "abc.com").rstrip(".").lower()
SINKHOLE_IP      = os.getenv("SINKHOLE_IP", "10.255.255.10")
SINKHOLE_ENABLED = os.getenv("SINKHOLE_ENABLED", "false")
INTERVAL         = int(os.getenv("BEACON_INTERVAL", "20"))
CALLBACK_PORT    = int(os.getenv("CALLBACK_PORT", "8080"))


def log(msg):
    print(f"[infected-pc] {msg}", flush=True)


def resolve_via_firewall(domain):
    """Send an A query for `domain` to the firewall DNS gateway."""
    fw_ip = socket.gethostbyname(DNS_SERVER)  # CoreDNS resolves the service name
    q = DNSRecord.question(domain, "A")
    data = q.send(fw_ip, DNS_PORT, tcp=False, timeout=4)
    ans = DNSRecord.parse(data)
    if ans.header.rcode != RCODE.NOERROR:
        return None, RCODE[ans.header.rcode]
    ips = [str(rr.rdata) for rr in ans.rr if QTYPE[rr.rtype] == "A"]
    return (ips[0] if ips else None), "NOERROR"


def attempt_callback(ip):
    """Try a short TCP connect to the resolved C2 IP (expected to fail in-lab)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect((ip, CALLBACK_PORT))
        s.close()
        return True
    except Exception as e:
        return False
    finally:
        try:
            s.close()
        except Exception:
            pass


def beacon():
    ip, rcode = resolve_via_firewall(MALICIOUS_DOMAIN)
    if ip is None:
        log(f"beacon: {MALICIOUS_DOMAIN} did NOT resolve ({rcode})")
        return

    if ip == SINKHOLE_IP:
        reached = attempt_callback(ip)
        log(f"[CONTAINED] {MALICIOUS_DOMAIN} -> {ip} (SINKHOLE). "
            f"C2 callback {'succeeded?!' if reached else 'blocked'} - beacon neutralized.")
    else:
        reached = attempt_callback(ip)
        log(f"[UNCONTAINED] {MALICIOUS_DOMAIN} -> {ip} (attacker C2). "
            f"C2 callback {'reached' if reached else 'attempted (unreachable in-lab)'} "
            f"- no sinkhole, malware would exfiltrate.")


def main():
    log(f"starting. resolver={DNS_SERVER}:{DNS_PORT} target={MALICIOUS_DOMAIN} "
        f"SINKHOLE_ENABLED={SINKHOLE_ENABLED} interval={INTERVAL}s")
    time.sleep(5)  # let DNS/firewall settle
    while True:
        try:
            beacon()
        except Exception as e:
            log(f"beacon error: {e}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()

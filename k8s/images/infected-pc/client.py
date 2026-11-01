#!/usr/bin/env python3
"""
infected-pc: the simulated compromised endpoint.

On a loop it behaves like malware beaconing to its C2:
  1. Ask the firewall (DNS_SERVER:8053) to resolve the malicious C2 domain.
  2. Inspect the answer:
       - SINKHOLE_IP  -> the firewall sinkholed us; beacon is CONTAINED.
       - attacker IP  -> resolution succeeded; beacon is UNCONTAINED.
  3. HTTP check-in to the resolved IP. Sinkholed -> the callback is blocked by
     NetworkPolicy. Uncontained -> the name resolves to the fake attacker C2 in
     the fake-internet namespace, which records the check-in and returns a fake
     tasking.
  4. Browse one benign public site (BROWSE_DOMAIN) via the same resolver; it
     lands on the fake-internet web server.

All behavior is read from the ConfigMap-backed environment.
"""
import json
import os
import time
import socket
import urllib.request

from dnslib import DNSRecord, QTYPE, RCODE

DNS_SERVER       = os.getenv("DNS_SERVER", "firewall-sim.cyber-range.svc.cluster.local")
DNS_PORT         = int(os.getenv("DNS_SERVER_PORT", "8053"))
MALICIOUS_DOMAINS = [d.strip().rstrip(".").lower()
                     for d in os.getenv("MALICIOUS_DOMAIN", "teq.xyz.com").split(",") if d.strip()]
ALT_DOMAIN       = os.getenv("ALT_DOMAIN", "abc.com").rstrip(".").lower()
SINKHOLE_IP      = os.getenv("SINKHOLE_IP", "10.255.255.10")
SINKHOLE_ENABLED = os.getenv("SINKHOLE_ENABLED", "false")
INTERVAL         = int(os.getenv("BEACON_INTERVAL", "20"))
CALLBACK_PORT    = int(os.getenv("CALLBACK_PORT", "80"))
BROWSE_DOMAIN    = os.getenv("BROWSE_DOMAIN", "www.example.com").strip().rstrip(".").lower()
IMPLANT_ID       = socket.gethostname()


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


def http_to(ip, host, path, body=None):
    """HTTP request to `ip` with a Host header, like malware that resolved `host`."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://{ip}:{CALLBACK_PORT}{path}", data=data,
                                 headers={"Host": host, "User-Agent": "Mozilla/5.0 (range implant)",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=3) as r:
        return r.status, r.read(4096)


def checkin(ip, domain):
    """C2 check-in. Returns (reached, detail)."""
    try:
        _, raw = http_to(ip, domain, "/checkin",
                         {"implant": IMPLANT_ID, "domain": domain, "ts": time.time()})
    except Exception as e:
        return False, type(e).__name__
    try:
        task = json.loads(raw.decode() or "{}")
        return True, f"task {task.get('task_id', '?')} '{task.get('command', '?')}'"
    except ValueError:
        return True, "non-JSON reply"


def beacon(domain):
    ip, rcode = resolve_via_firewall(domain)
    if ip is None:
        log(f"beacon: {domain} did NOT resolve ({rcode})")
        return

    reached, detail = checkin(ip, domain)
    if ip == SINKHOLE_IP:
        log(f"[CONTAINED] {domain} -> {ip} (SINKHOLE). "
            f"C2 check-in {'reached?! ' + detail if reached else 'blocked'} - beacon neutralized.")
    else:
        log(f"[UNCONTAINED] {domain} -> {ip} (attacker C2). "
            f"C2 check-in {'REACHED fake C2, got ' + detail if reached else 'failed (' + detail + ')'} "
            f"- no sinkhole, implant is talking to its C2.")


def browse():
    if not BROWSE_DOMAIN:
        return
    ip, rcode = resolve_via_firewall(BROWSE_DOMAIN)
    if ip is None:
        log(f"browse: {BROWSE_DOMAIN} did NOT resolve ({rcode})")
        return
    try:
        status, _ = http_to(ip, BROWSE_DOMAIN, "/")
        log(f"browse: http://{BROWSE_DOMAIN}/ -> {ip} HTTP {status}")
    except Exception as e:
        log(f"browse: http://{BROWSE_DOMAIN}/ -> {ip} failed ({type(e).__name__})")


def main():
    log(f"starting. resolver={DNS_SERVER}:{DNS_PORT} targets={','.join(MALICIOUS_DOMAINS)} "
        f"SINKHOLE_ENABLED={SINKHOLE_ENABLED} interval={INTERVAL}s")
    time.sleep(5)  # let DNS/firewall settle
    while True:
        for domain in MALICIOUS_DOMAINS:
            try:
                beacon(domain)
            except Exception as e:
                log(f"beacon error ({domain}): {e}")
        try:
            browse()
        except Exception as e:
            log(f"browse error: {e}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()

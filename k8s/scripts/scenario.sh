#!/usr/bin/env bash
# Use-case scenario runner.
#
# Story: a compromised workstation (infected-pc) beacons to its C2 domain
# (teq.xyz.com) while the user also browses a benign site (abc.com). We run the
# SAME probes through the firewall in BOTH variants and compare the outcome.
#
# For each variant it: swaps the ConfigMap, then from INSIDE the infected-pc pod
# resolves both domains via the firewall (:8053) and attempts a C2 callback,
# then prints the firewall / sinkhole / external-dns evidence.
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=cyber-range

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }

probe() {
  # Resolve $1 via the firewall from within infected-pc and try a callback.
  $KUBECTL -n "$NS" exec -i deploy/infected-pc -- python - "$1" <<'PY'
import os, sys, socket
from dnslib import DNSRecord, QTYPE, RCODE
dns  = os.getenv("DNS_SERVER"); port = int(os.getenv("DNS_SERVER_PORT", "8053"))
sink = os.getenv("SINKHOLE_IP", "10.255.255.10")
domain = sys.argv[1]
fw = socket.gethostbyname(dns)
ans = DNSRecord.parse(DNSRecord.question(domain, "A").send(fw, port, timeout=4))
if ans.header.rcode != RCODE.NOERROR:
    print(f"  {domain:14s} -> RCODE={RCODE[ans.header.rcode]}"); sys.exit()
ips = [str(r.rdata) for r in ans.rr if QTYPE[r.rtype] == "A"]
ip = ips[0] if ips else None
verdict = ""
if ip == sink:
    verdict = "  [SINKHOLED -> contained]"
elif ip:
    verdict = "  [resolved -> would reach host]"
# short callback attempt
reached = False
if ip:
    s = socket.socket(); s.settimeout(2)
    try: s.connect((ip, 8080)); reached = True
    except Exception: pass
    finally: s.close()
cb = "callback OK" if reached else "callback blocked/unreachable"
print(f"  {domain:14s} -> {ip or '(none)':16s} {verdict}  ({cb})")
PY
}

run_variant() {
  local v="$1"
  bash "$HERE/toggle-variant.sh" "$v" >/dev/null 2>&1
  sleep 6
  bold "================ VARIANT: sinkhole=$v ================"
  echo "range-mode: $($KUBECTL -n $NS get cm range-mode -o jsonpath='{.data.SINKHOLE_ENABLED}')"
  echo "-- DNS probes through firewall (from infected-pc) --"
  probe abc.com       # benign  (user browsing)
  probe teq.xyz.com   # malicious (C2 beacon)
  echo "-- firewall decision (last) --"
  $KUBECTL -n $NS logs deploy/firewall-sim --tail=8 | grep -E 'SINKHOLE|ALERT|FORWARD' | tail -2 || true
  echo "-- sinkhole captures (count) --"
  echo "  $($KUBECTL -n $NS logs deploy/sinkhole | grep -c CAPTURE || true) total"
  echo "-- external-dns malicious answers (count) --"
  echo "  $($KUBECTL -n dns-system logs deploy/external-dns | grep -c 'ATTACKER C2' || true) total"
}

run_variant with
run_variant without

bold "================ SUMMARY ================"
cat <<'EOF'
  abc.com     (benign)    : resolves in BOTH variants -> legitimate traffic unaffected
  teq.xyz.com (malicious) :
     sinkhole ON  -> firewall returns SINKHOLE_IP, capture logged   => CONTAINED
     sinkhole OFF -> firewall forwards to attacker DNS (203.0.113.66) => UNCONTAINED
EOF

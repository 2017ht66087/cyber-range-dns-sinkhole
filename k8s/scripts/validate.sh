#!/usr/bin/env bash
# Show the evidence trail for whichever variant is running:
#   - current range-mode ConfigMap
#   - infected-pc verdict (CONTAINED / UNCONTAINED)
#   - firewall-sim decisions (SINKHOLE / ALERT / FORWARD)
#   - sinkhole captures
#   - fake-internet activity (fake C2 check-ins + web requests)
#   - corp servers: AD replication/LDAP/Kerberos, DB queries, web, corp.lab DNS
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
TAIL="${TAIL:-15}"

hr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hr "range-mode ConfigMap"
$KUBECTL -n cyber-range get configmap range-mode -o jsonpath='{.data}' 2>/dev/null; echo

hr "pods"
$KUBECTL get pods -n cyber-range
$KUBECTL get pods -n dns-system
$KUBECTL get pods -n fake-internet

hr "infected-pc (verdict)"
$KUBECTL -n cyber-range logs deploy/infected-pc --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

hr "firewall-sim (policy decisions)"
$KUBECTL -n cyber-range logs deploy/firewall-sim --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

hr "sinkhole (captures)"
$KUBECTL -n cyber-range logs deploy/sinkhole --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

hr "external-dns (attacker resolver)"
$KUBECTL -n dns-system logs deploy/external-dns --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

hr "fake-internet (fake C2 check-ins + web requests)"
$KUBECTL -n fake-internet logs deploy/fake-internet --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"
CHECKINS="$($KUBECTL -n fake-internet logs deploy/fake-internet 2>/dev/null | grep -c 'C2 CHECK-IN' || true)"
echo "C2 check-ins logged since pod start: ${CHECKINS:-0}  (sinkhole ON should keep this at 0)"

if $KUBECTL get namespace corp >/dev/null 2>&1; then
  C="$KUBECTL -n corp"
  hr "corp servers (AD / DB / web)"
  $C get pods -o wide
  echo "-- AD replication (samba-tool drs showrepl --summary)"
  for dc in dc01 dc02; do printf '%s: ' "$dc"; $C exec deploy/$dc -- samba-tool drs showrepl --summary 2>&1 | head -1 || true; done
  echo "-- AD users (dc02) + LDAP rootDSE / Kerberos KDC on dc01"
  $C exec deploy/dc02 -- samba-tool user list 2>/dev/null | sort | tr '\n' ' ' || true; echo
  $C exec deploy/dc02 -- ldapsearch -LLL -x -H ldap://dc01.corp.lab -s base -b "" dnsHostName 2>/dev/null | grep dnsHostName || echo "LDAP: no answer"
  $C exec deploy/dc02 -- sh -c 'echo | kinit nobody@CORP.LAB 2>&1 | grep -q "not found in Kerberos database" && echo "Kerberos: KDC answering" || echo "Kerberos: no answer"' || true
  echo "-- databases"
  $C exec deploy/db01 -- psql -U postgres -d corp -Atc "select 'db01 hr.employees rows: ' || count(*) from hr.employees" 2>&1 || true
  $C exec deploy/db02 -- sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" crm -BNe "select concat(\"db02 crm.customers rows: \", count(*)) from customers"' 2>&1 || true
  echo "-- web (web01 intranet, web01 -> web02 -> db01/db02)"
  $C exec deploy/web02 -- python -c "import urllib.request as u
for url in ('http://web01.corp.svc.cluster.local/', 'http://web01.corp.svc.cluster.local/app/'):
    r = u.urlopen(url, timeout=10); b = r.read().decode()
    print(r.status, url, '(db01 data shown)' if 'Alice Anders' in b else '')" 2>&1 || true
  echo "-- internal-dns answers for *.corp.lab"
  $KUBECTL -n dns-system exec deploy/internal-dns -- python -c "from dnslib import DNSRecord
for h in ('dc01', 'dc02', 'db01', 'db02', 'web01', 'web02'):
    r = DNSRecord.parse(DNSRecord.question(h + '.corp.lab').send('127.0.0.1', 53, timeout=3))
    print(h + '.corp.lab ->', ', '.join(str(a.rdata) for a in r.rr) or 'NXDOMAIN')" 2>&1 || true
fi

echo
echo "Tip: live-follow the endpoint with:"
echo "  $KUBECTL -n cyber-range logs -f deploy/infected-pc"

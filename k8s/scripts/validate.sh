#!/usr/bin/env bash
# Show the evidence trail for whichever variant is running:
#   - current range-mode ConfigMap
#   - infected-pc verdict (CONTAINED / UNCONTAINED)
#   - firewall-sim decisions (SINKHOLE / ALERT / FORWARD)
#   - sinkhole captures
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
TAIL="${TAIL:-15}"

hr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hr "range-mode ConfigMap"
$KUBECTL -n cyber-range get configmap range-mode -o jsonpath='{.data}' 2>/dev/null; echo

hr "pods"
$KUBECTL get pods -n cyber-range
$KUBECTL get pods -n dns-system

hr "infected-pc (verdict)"
$KUBECTL -n cyber-range logs deploy/infected-pc --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

hr "firewall-sim (policy decisions)"
$KUBECTL -n cyber-range logs deploy/firewall-sim --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

hr "sinkhole (captures)"
$KUBECTL -n cyber-range logs deploy/sinkhole --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

hr "external-dns (attacker resolver)"
$KUBECTL -n dns-system logs deploy/external-dns --tail="$TAIL" 2>/dev/null || echo "(no logs yet)"

echo
echo "Tip: live-follow the endpoint with:"
echo "  $KUBECTL -n cyber-range logs -f deploy/infected-pc"

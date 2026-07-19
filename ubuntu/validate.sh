#!/usr/bin/env bash
# Automated validation checklist. Run FROM a USERS-zone host (e.g. a Linux
# EP-INFECTED) after setting a scenario path. Usage: ./validate.sh A|B
source "$(dirname "$0")/lib.sh"

PATHSEL="${1:?Path required: A or B}"
domain="$MAL_DOMAIN"
fails=0
result() { # NAME OK DETAIL
  if [ "$2" = 1 ]; then printf '  \033[32mPASS\033[0m  %-52s %s\n' "$1" "$3"
  else printf '  \033[31mFAIL\033[0m  %-52s %s\n' "$1" "$3"; fails=$((fails+1)); fi
}

echo "=== Cyber Range Validation - Path $PATHSEL ==="

# 1) Isolation: no route to real internet.
if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then net=1; else net=0; fi
result "Isolation: no internet (8.8.8.8 unreachable)" "$([ $net = 0 ] && echo 1 || echo 0)" "reachable=$net (want 0)"

# 2) DNS resolves per active path.
expected="$SINKHOLE_IP"; [ "$PATHSEL" = B ] && expected="$ATTACKER_IP"
got=$(dig +short "$domain" 2>/dev/null | head -1)
result "DNS: $domain -> $expected" "$([ "$got" = "$expected" ] && echo 1 || echo 0)" "got=${got:-none}"

# 3) Callback reachability differs by path.
if curl -s -m5 -o /dev/null "http://$domain/checkin"; then cb=1; else cb=0; fi
if [ "$PATHSEL" = A ]; then
  result "Containment: C2 callback BLOCKED" "$([ $cb = 0 ] && echo 1 || echo 0)" "callbackOK=$cb (want 0)"
else
  result "Exposure: C2 callback SUCCEEDS" "$([ $cb = 1 ] && echo 1 || echo 0)" "callbackOK=$cb (want 1)"
fi

echo
if [ "$fails" = 0 ]; then ok "ALL CHECKS PASSED for Path $PATHSEL."; exit 0
else err "$fails check(s) FAILED for Path $PATHSEL."; exit 1; fi

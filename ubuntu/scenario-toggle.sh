#!/usr/bin/env bash
# Flip the range between Path A (sinkhole ON) and Path B (sinkhole OFF).
# Pushes DHCP DNS (USERS zone) + firewall R4/R6 state to SEC-GW over SSH.
# Usage: ./scenario-toggle.sh A|B [gateway_host] [gateway_user]
source "$(dirname "$0")/lib.sh"

PATHSEL="${1:?Path required: A or B}"
GW_HOST="${2:-10.10.10.1}"
GW_USER="${3:-admin}"

case "$PATHSEL" in
  A) DNS="$INTERNAL_DNS"; STATE=disable
     DESC="Path A / SINKHOLE ON  -> USERS DNS=$DNS ; $MAL_DOMAIN -> $SINKHOLE_IP ; C2 blocked";;
  B) DNS="$EXTERNAL_DNS"; STATE=enable
     DESC="Path B / SINKHOLE OFF -> USERS DNS=$DNS ; $MAL_DOMAIN -> $ATTACKER_IP ; C2 reachable";;
  *) err "Path must be A or B"; exit 1;;
esac

say "$DESC"

# Commands run on SEC-GW (pfSense playback / OPNsense configctl). Explicit for audit.
read -r -d '' REMOTE <<EOF || true
# set USERS-zone DHCP DNS to $DNS
pfSsh.php playback setdhcpdns range-users $DNS
# R4 (USERS->EXT-DNS:53) and R6 (USERS->ATK-C2) => $STATE
pfSsh.php playback rule USERS EXT-DNS $STATE
pfSsh.php playback rule USERS ATK-C2 $STATE
pfctl -f /tmp/rules.debug
EOF

if [ "$DRY_RUN" = 1 ]; then
  echo "    DRYRUN> ssh $GW_USER@$GW_HOST 'sh -s' <<'CMDS'"
  echo "$REMOTE" | sed 's/^/      /'
  echo "    CMDS"
else
  say "Pushing to SEC-GW ($GW_USER@$GW_HOST)"
  printf '%s\n' "$REMOTE" | ssh "$GW_USER@$GW_HOST" 'sh -s'
  ok "Applied. On EP-INFECTED run: dhclient -r && dhclient (or ipconfig /renew)."
fi

ok "Scenario set to Path $PATHSEL."
echo "    Verify from EP-INFECTED:  dig +short $MAL_DOMAIN"
echo "    Expected: Path A -> $SINKHOLE_IP  |  Path B -> $ATTACKER_IP"

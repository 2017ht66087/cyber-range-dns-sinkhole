#!/usr/bin/env bash
# Power the range on/off in dependency order (tier column).
# Usage: ./03-boot-order.sh start [snapshot-to-revert]
#        ./03-boot-order.sh stop
source "$(dirname "$0")/lib.sh"

ACTION="${1:-start}"
REVERT="${2:-}"
DELAY="${TIER_DELAY:-45}"

tiers=$(tsv "$INV_VM" | awk -F'\t' '{print $7}' | sort -un)
[ "$ACTION" = stop ] && tiers=$(echo "$tiers" | sort -rn)

for t in $tiers; do
  vms=$(tsv "$INV_VM" | awk -F'\t' -v t="$t" '$7==t{print $1}')
  say "$ACTION tier $t: $(echo "$vms" | tr '\n' ' ')"
  for vm in $vms; do
    "$VIRSH" dominfo "$vm" >/dev/null 2>&1 || { warn "$vm not defined - skip"; continue; }
    if [ "$ACTION" = start ]; then
      [ -n "$REVERT" ] && run "$VIRSH" snapshot-revert "$vm" "$REVERT"
      run "$VIRSH" start "$vm" 2>/dev/null || warn "$vm already running"
    else
      run "$VIRSH" shutdown "$vm" 2>/dev/null || warn "$vm not running"
    fi
  done
  last=$(echo "$tiers" | tail -1)
  if [ "$ACTION" = start ] && [ "$t" != "$last" ]; then
    say "waiting ${DELAY}s for tier $t to settle"; [ "$DRY_RUN" = 1 ] || sleep "$DELAY"
  fi
done
ok "$ACTION complete."

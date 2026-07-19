#!/usr/bin/env bash
# Reset / clean / destroy the range.
#   reset   : revert all to scenario-armed (fast)
#   clean   : revert all to baseline-clean
#   destroy : destroy + undefine all VMs and remove overlays (networks kept)
#   nuke    : destroy VMs AND remove the libvirt networks
# Usage: ./99-teardown.sh <reset|clean|destroy|nuke> [--yes]
source "$(dirname "$0")/lib.sh"

MODE="${1:-reset}"; CONFIRM="${2:-}"
case "$MODE" in reset) SNAP="$SNAP_ARMED";; clean) SNAP="$SNAP_CLEAN";; destroy|nuke) SNAP="";; *) err "unknown mode $MODE"; exit 1;; esac
if { [ "$MODE" = destroy ] || [ "$MODE" = nuke ]; } && [ "$CONFIRM" != "--yes" ] && [ "$DRY_RUN" != 1 ]; then
  err "$MODE is irreversible. Re-run with --yes (export evidence to MGMT-BKP first)."; exit 1
fi

# Reverse tier order for shutdown.
for t in $(tsv "$INV_VM" | awk -F'\t' '{print $7}' | sort -rn); do
  for vm in $(tsv "$INV_VM" | awk -F'\t' -v t="$t" '$7==t{print $1}'); do
    "$VIRSH" dominfo "$vm" >/dev/null 2>&1 || continue
    say "$MODE: $vm"
    if [ -n "$SNAP" ]; then
      run "$VIRSH" destroy "$vm" 2>/dev/null || true
      run "$VIRSH" snapshot-revert "$vm" "$SNAP"
    else
      run "$VIRSH" destroy "$vm" 2>/dev/null || true
      run "$VIRSH" undefine "$vm" --nvram --snapshots-metadata 2>/dev/null || run "$VIRSH" undefine "$vm"
      run rm -f "$POOL_DIR/$vm.qcow2"
    fi
  done
done

if [ "$MODE" = nuke ]; then
  for net in $(tsv "$INV_NET" | awk -F'\t' '{print $1}'); do
    run "$VIRSH" net-destroy "$net" 2>/dev/null || true
    run "$VIRSH" net-undefine "$net" 2>/dev/null || true
  done
fi
ok "$MODE complete."

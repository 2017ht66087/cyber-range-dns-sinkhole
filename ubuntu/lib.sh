#!/usr/bin/env bash
# =====================================================================
# lib.sh - shared helpers/inventory for the Ubuntu (KVM/libvirt) kit
# Source it:  source "$(dirname "$0")/lib.sh"
# =====================================================================
set -euo pipefail

CR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$CR_ROOT/../config" && pwd)"
INV_NET="$CR_ROOT/inventory/networks.tsv"
INV_VM="$CR_ROOT/inventory/vms.tsv"

# Overridable via environment.
IMAGES_DIR="${CR_IMAGES_DIR:-/var/lib/libvirt/images/cyberrange/base}"   # base qcow2 images
POOL_DIR="${CR_POOL_DIR:-/var/lib/libvirt/images/cyberrange}"            # per-VM overlays
BUILD_DIR="${CR_BUILD_DIR:-$CR_ROOT/.build}"                             # generated cloud-init
VIRSH="${VIRSH:-virsh}"
DRY_RUN="${DRY_RUN:-0}"

# Virtualization type: use KVM when /dev/kvm exists, else fall back to slow
# QEMU TCG emulation (e.g. on hosts where nested VT-x is unavailable).
CR_VIRT_TYPE="${CR_VIRT_TYPE:-$([ -e /dev/kvm ] && echo kvm || echo qemu)}"

SNAP_CLEAN="baseline-clean"
SNAP_ARMED="scenario-armed"

# Scenario resolution targets (mirror ../config/inventory.psd1).
SINKHOLE_IP="10.10.60.5"
# Laptop trim: SVC-DC is not deployed. Path A uses SVC-SINK.
INTERNAL_DNS="10.10.20.11"
EXTERNAL_DNS="10.10.50.53"
ATTACKER_IP="10.10.40.10"
MAL_DOMAIN="updates.evil-c2.range"

say()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

# run CMD... ; honors DRY_RUN=1 by printing instead of executing.
run() {
  if [ "$DRY_RUN" = "1" ]; then printf '    DRYRUN> %s\n' "$*"; else "$@"; fi
}

# Iterate a TSV, skipping comment/blank lines.
tsv() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

# Zone gateway = .1 of the VM's first network subnet (pfSense leg).
gw_for_ip() { echo "${1%.*}.1"; }

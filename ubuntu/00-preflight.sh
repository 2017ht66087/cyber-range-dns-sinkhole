#!/usr/bin/env bash
# Preflight for the Ubuntu/KVM cyber range. Read-only.
source "$(dirname "$0")/lib.sh"

pass=0
say "Cyber Range (KVM/libvirt) preflight..."

# --- Virtualization stack ---
for bin in virsh virt-install qemu-img kvm-ok; do
  if command -v "$bin" >/dev/null 2>&1; then ok "found: $bin"
  else warn "missing: $bin  (apt install qemu-kvm libvirt-daemon-system virtinst cpu-checker)"; [ "$bin" = kvm-ok ] || pass=1; fi
done

# --- KVM acceleration ---
# CR_ALLOW_EMULATION=1 downgrades missing-acceleration from fatal to a warning
# and lets the kit run under slow QEMU TCG emulation (Linux-only, tiny guests).
accel_fail() {
  if [ "${CR_ALLOW_EMULATION:-0}" = "1" ]; then
    warn "$1 -> CR_ALLOW_EMULATION=1 set: using slow QEMU TCG emulation (Linux-only)."
  else
    err "$1 (set CR_ALLOW_EMULATION=1 to force slow emulation)."; pass=1
  fi
}
if command -v kvm-ok >/dev/null 2>&1; then
  kvm-ok || accel_fail "KVM acceleration unavailable (enable VT-x/AMD-V, or disable host VBS/Hyper-V)"
elif [ -e /dev/kvm ]; then ok "/dev/kvm present"
else accel_fail "/dev/kvm missing - no hardware virtualization"; fi

# --- libvirtd running + user in group ---
if systemctl is-active --quiet libvirtd 2>/dev/null; then ok "libvirtd active"; else warn "libvirtd not active: systemctl enable --now libvirtd"; fi
id -nG 2>/dev/null | grep -qw libvirt && ok "user in 'libvirt' group" || warn "add user to libvirt group: sudo usermod -aG libvirt \$USER (re-login)"

# --- Resources ---
ram=$(awk '/MemTotal/{printf "%.1f",$2/1048576}' /proc/meminfo 2>/dev/null || echo "?")
cpu=$(nproc 2>/dev/null || echo "?")
free=$(df -BG --output=avail "$(dirname "$POOL_DIR")" 2>/dev/null | tail -1 | tr -dc '0-9' || echo "?")
say "RAM=${ram}GB vCPU=${cpu} Free(${POOL_DIR%/*})=${free}GB"
awk "BEGIN{exit !($ram < 10)}" 2>/dev/null && warn "RAM < 10GB: trimmed inventory still needs ~7GB guests + host OS"

# --- Inventory ---
[ -f "$INV_NET" ] && ok "networks.tsv: $(tsv "$INV_NET" | wc -l) networks" || { err "missing $INV_NET"; pass=1; }
[ -f "$INV_VM" ]  && ok "vms.tsv: $(tsv "$INV_VM" | wc -l) VMs"          || { err "missing $INV_VM"; pass=1; }

# --- Base images ---
say "Checking base images in $IMAGES_DIR"
while IFS=$'\t' read -r name role base _; do
  if [ -f "$IMAGES_DIR/$base" ]; then ok "image present: $base"; else warn "MISSING base image: $base (needed by $name)"; fi
done < <(tsv "$INV_VM")

echo
if [ "$pass" = 0 ]; then ok "PREFLIGHT PASSED - resolve warnings, then ./01-create-networks.sh"; else err "PREFLIGHT FAILED - install the KVM stack (see README)."; fi
exit "$pass"

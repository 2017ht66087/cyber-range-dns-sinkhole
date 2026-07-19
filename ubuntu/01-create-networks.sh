#!/usr/bin/env bash
# Define + start the six isolated libvirt networks from inventory/networks.tsv.
# No <forward> => no NAT/route to the internet. No <dhcp> => SEC-GW serves DHCP.
source "$(dirname "$0")/lib.sh"

command -v "$VIRSH" >/dev/null || { err "virsh not found. Install libvirt."; exit 1; }
mkdir -p "$BUILD_DIR"

while IFS=$'\t' read -r name bridge cidr host_ip access zone; do
  say "Network $name ($zone) $cidr  access=$access"
  xml="$BUILD_DIR/net-$name.xml"
  {
    echo "<network>"
    echo "  <name>$name</name>"
    echo "  <bridge name='$bridge' stp='on' delay='0'/>"
    if [ "$access" = "yes" ] && [ "$host_ip" != "-" ]; then
      # Host gets a bridge IP for admin/analyst access; still isolated (no forward).
      echo "  <ip address='$host_ip' netmask='255.255.255.0'/>"
    fi
    echo "</network>"
  } > "$xml"

  if "$VIRSH" net-info "$name" >/dev/null 2>&1; then
    warn "$name already defined - skipping define."
  else
    run "$VIRSH" net-define "$xml"
  fi
  run "$VIRSH" net-autostart "$name"
  run "$VIRSH" net-start "$name" 2>/dev/null || warn "$name already active."
  ok "$name ready (bridge $bridge)."
done < <(tsv "$INV_NET")

ok "Network stage complete. Next: ./02-deploy-vms.sh"

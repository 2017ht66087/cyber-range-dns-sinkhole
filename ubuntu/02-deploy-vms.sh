#!/usr/bin/env bash
# Create per-VM qcow2 overlays from base images, generate cloud-init for Linux
# service guests, import each domain with the right isolated networks, and take
# the baseline-clean snapshot. Windows/pfSense guests skip cloud-init.
source "$(dirname "$0")/lib.sh"

command -v virt-install >/dev/null || { err "virt-install not found."; exit 1; }
run mkdir -p "$POOL_DIR" "$BUILD_DIR"

# Which os-variants get NoCloud cloud-init (Linux images with cloud-init baked in).
is_linux_ci() { case "$1" in ubuntu*|debian*|generic) return 0;; *) return 1;; esac; }

# render_cloudinit NAME ROLE IP OSVARIANT  -> sets global CI_ARGS ("" if none)
render_cloudinit() {
  local name="$1" role="$2" ip="$3" osv="$4"
  CI_ARGS=""
  is_linux_ci "$osv" || return 0
  [ "${ip%%-*}" = "dhcp" ] && ip=""       # dhcp endpoints: no static config
  local dir="$BUILD_DIR/ci/$name"; run mkdir -p "$dir"
  [ "$DRY_RUN" = 1 ] && mkdir -p "$dir" 2>/dev/null || true

  # network-config (static IP) unless DHCP
  local netcfg="$dir/network-config"
  if [ -n "$ip" ]; then
    local gw; gw="$(gw_for_ip "$ip")"
    local dns="$INTERNAL_DNS"
    case "$role" in ext-dns|mock-inet) dns="10.10.50.1";; esac
    cat > "$netcfg" <<EOF
version: 2
ethernets:
  range0:
    match: {name: "en*"}
    addresses: [$ip/24]
    routes: [{to: default, via: $gw}]
    nameservers: {addresses: [$dns]}
EOF
  else
    printf 'version: 2\nethernets:\n  range0:\n    match: {name: "en*"}\n    dhcp4: true\n' > "$netcfg"
  fi

  # user-data: hostname + per-role service config (NO apt; range is offline).
  local ud="$dir/user-data"
  { echo "#cloud-config"; echo "hostname: ${name,,}"; echo "manage_etc_hosts: true"; } > "$ud"
  local conf="" dest="" svc=""
  case "$role" in
    sinkhole)  conf="$CONFIG_DIR/unbound-sinkhole.conf"; dest="/etc/unbound/unbound.conf.d/sinkhole.conf"; svc="unbound";;
    ext-dns)   conf="$CONFIG_DIR/dnsmasq-external.conf"; dest="/etc/dnsmasq.d/external.conf";             svc="dnsmasq";;
    mock-inet) conf="$CONFIG_DIR/inetsim.conf";          dest="/etc/inetsim/inetsim.conf";                svc="inetsim";;
  esac
  if [ -n "$conf" ] && [ -f "$conf" ]; then
    {
      echo "write_files:"
      echo "  - path: $dest"
      echo "    permissions: '0644'"
      echo "    encoding: b64"
      echo "    content: $(base64 -w0 "$conf")"
      echo "runcmd:"
      echo "  - [ systemctl, enable, --now, $svc ]"
      echo "  - [ systemctl, restart, $svc ]"
    } >> "$ud"
  fi
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "${name,,}" > "$dir/meta-data"
  CI_ARGS="--cloud-init user-data=$ud,network-config=$netcfg"
}

while IFS=$'\t' read -r name role base osv vcpu mem tier nets ip; do
  say "Deploy $name [$role] tier $tier  base=$base"
  local_overlay="$POOL_DIR/$name.qcow2"
  base_img="$IMAGES_DIR/$base"

  if "$VIRSH" dominfo "$name" >/dev/null 2>&1; then warn "$name already defined - skipping."; continue; fi
  if [ ! -f "$base_img" ] && [ "$DRY_RUN" != 1 ]; then warn "base image missing ($base_img) - skipping $name."; continue; fi

  run qemu-img create -f qcow2 -F qcow2 -b "$base_img" "$local_overlay"

  netargs=""
  IFS=',' read -ra nlist <<< "$nets"
  for n in "${nlist[@]}"; do netargs+=" --network network=$n,model=virtio"; done

  render_cloudinit "$name" "$role" "$ip" "$osv"

  run virt-install --name "$name" --memory "$mem" --vcpus "$vcpu" \
      --virt-type "$CR_VIRT_TYPE" \
      --disk path="$local_overlay",format=qcow2,bus=virtio \
      --import --os-variant "$osv" --graphics none --noautoconsole \
      $netargs $CI_ARGS

  run "$VIRSH" snapshot-create-as "$name" "$SNAP_CLEAN" "clean baseline" >/dev/null
  ok "$name deployed (nets: $nets)"
done < <(tsv "$INV_VM")

ok "Deploy complete. Configure guests (Ansible), snapshot '$SNAP_ARMED', then ./03-boot-order.sh start"

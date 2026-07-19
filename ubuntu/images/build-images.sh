#!/usr/bin/env bash
# =====================================================================
# build-images.sh - reproducibly build the base qcow2 templates that
# deploy-range.sh / 02-deploy-vms.sh clone from.
#
#   cloud        (debian12, ubuntu22, kali)  -> FULLY AUTOMATED
#   opnsense-img (opnsense)                   -> AUTOMATED (serial image, no installer)
#   iso-install  (win2022, win10, seconion)   -> ASSISTED  (you supply the ISO)
#
# Output goes to $CR_IMAGES_DIR (default /var/lib/libvirt/images/cyberrange/base)
# so it lands exactly where the deploy scripts expect it.
#
# Usage:
#   ./build-images.sh [--list] [--force] [-n|--dry-run] [name ...]
#   (no names = build every 'cloud'/'opnsense-img' row; iso rows need their ISO env)
# ISO env vars (for assisted builds): WIN2022_ISO, WIN10_ISO, SO_ISO
#   plus optional VIRTIO_WIN_ISO for Windows driver injection.
# =====================================================================
source "$(dirname "$0")/../lib.sh"
set +e

IMG_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$IMG_DIR/manifest.tsv"
CACHE="${CR_CACHE_DIR:-$IMG_DIR/.cache}"
FORCE=0
SELECT=()

for a in "$@"; do
  case "$a" in
    --list)     tsv "$MANIFEST" | awk -F'\t' '{printf "  %-14s %-14s %s\n",$1,$2,$3}'; exit 0 ;;
    --force)    FORCE=1 ;;
    -n|--dry-run) export DRY_RUN=1 ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         err "unknown option $a"; exit 2 ;;
    *)          SELECT+=("$a") ;;
  esac
done

LOG_DIR="$CR_ROOT/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/build-images-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
say "Image build starting. Log: $LOG  DRY_RUN=${DRY_RUN:-0}"

# --- Dependency check ---
for bin in qemu-img curl; do command -v "$bin" >/dev/null || { err "missing $bin"; exit 1; }; done
command -v virt-customize >/dev/null || warn "virt-customize missing (apt install libguestfs-tools) - cloud builds need it."
command -v virt-install   >/dev/null || warn "virt-install missing - iso-install builds need it."

run mkdir -p "$IMAGES_DIR" "$CACHE"

download() { # URL DEST
  local url="$1" dest="$2"
  if [ -f "$dest" ] && [ "$FORCE" != 1 ]; then say "cached: $(basename "$dest")"; return 0; fi
  run curl -L --fail --retry 3 -o "$dest" "$url"
}

build_cloud() {
  local name="$1" osv="$2" url="$3" size="$4"
  local target="$IMAGES_DIR/$name.qcow2" cache="$CACHE/$name-$(basename "$url")"
  if [ -f "$target" ] && [ "$FORCE" != 1 ]; then warn "$name exists (use --force to rebuild)"; return 0; fi
  say "[cloud] $name  <- $url"
  download "$url" "$cache"
  run cp -f "$cache" "$target"
  run qemu-img resize "$target" "${size}G"

  local -a cz=(virt-customize -a "$target" --network --timezone UTC --run-command 'apt-get update')
  case "$name" in
    debian12)
      # union of packages for sinkhole/ext-dns/mock-inet/bastion/orch/backup roles
      cz+=(--run-command 'DEBIAN_FRONTEND=noninteractive apt-get install -y unbound dnsmasq nginx dnsutils curl qemu-guest-agent cloud-init; apt-get install -y inetsim || true')
      cz+=(--run-command 'systemctl disable unbound dnsmasq inetsim 2>/dev/null || true') ;;
    ubuntu22)
      cz+=(--run-command 'DEBIAN_FRONTEND=noninteractive apt-get install -y rsyslog curl dnsutils qemu-guest-agent cloud-init') ;;
    kali)
      cz+=(--copy-in "$IMG_DIR/assets/mock-c2.py:/opt")
      cz+=(--copy-in "$IMG_DIR/assets/mock-c2.service:/etc/systemd/system")
      cz+=(--run-command 'DEBIAN_FRONTEND=noninteractive apt-get install -y python3 curl dnsutils qemu-guest-agent cloud-init; chmod +x /opt/mock-c2.py; systemctl enable mock-c2') ;;
  esac
  run "${cz[@]}"
  ok "[cloud] built $name -> $target"
}

build_opnsense() {
  local name="$1" osv="$2" url="$3" size="$4"
  local target="$IMAGES_DIR/$name.qcow2"
  local bz="$CACHE/$(basename "$url")"
  local raw="${bz%.bz2}"
  if [ -f "$target" ] && [ "$FORCE" != 1 ]; then warn "$name exists (use --force)"; return 0; fi
  say "[opnsense] $name  <- $url"
  download "$url" "$bz"
  run bunzip2 -kf "$bz"
  run qemu-img convert -f raw -O qcow2 "$raw" "$target"
  run qemu-img resize "$target" "${size}G"
  ok "[opnsense] built $name -> $target (first boot: assign WAN-less LAN legs, set console)"
}

build_iso() {
  local name="$1" osv="$2" envvar="$3" size="$4"
  local iso="${!envvar:-}" target="$IMAGES_DIR/$name.qcow2"
  if [ -f "$target" ] && [ "$FORCE" != 1 ]; then warn "$name exists (use --force)"; return 0; fi
  if [ -z "$iso" ]; then warn "[iso] $name skipped: set $envvar=/path/to.iso (assisted build)"; return 0; fi
  say "[iso] $name  installer=$iso"
  run qemu-img create -f qcow2 "$target" "${size}G"

  local -a vi=(virt-install --name "build-$name" --memory 4096 --vcpus 2
               --disk path="$target",format=qcow2,bus=virtio
               --os-variant "$osv" --network none --graphics vnc --noautoconsole
               --cdrom "$iso")
  case "$osv" in
    win2k22|win10)
      [ -n "${VIRTIO_WIN_ISO:-}" ] && vi+=(--disk path="$VIRTIO_WIN_ISO",device=cdrom)
      warn "Windows: attach $IMG_DIR/win-autounattend/autounattend.xml (edit @@ placeholders) as a floppy/ISO for unattended setup." ;;
  esac
  run "${vi[@]}"
  warn "[iso] $name: installer VM 'build-$name' launched. Complete it via: virt-viewer build-$name"
  warn "[iso] when done:  virsh shutdown build-$name && virsh undefine build-$name  (disk $target is kept as the base image)"
}

dispatch() { # name type osv source size
  case "$2" in
    cloud)        build_cloud    "$1" "$3" "$4" "$5" ;;
    opnsense-img) build_opnsense "$1" "$3" "$4" "$5" ;;
    iso-install)  build_iso      "$1" "$3" "$4" "$5" ;;
    *) err "unknown type '$2' for $1" ;;
  esac
}

want() { # is NAME selected?
  [ "${#SELECT[@]}" -eq 0 ] && return 0
  local n; for n in "${SELECT[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1
}

count=0
while IFS=$'\t' read -r name type osv source size; do
  want "$name" || continue
  # By default skip iso-install rows unless explicitly selected or their ISO env is set.
  if [ "$type" = iso-install ] && [ "${#SELECT[@]}" -eq 0 ] && [ -z "${!source:-}" ]; then
    warn "skip $name (iso-install; set $source or name it explicitly)"; continue
  fi
  printf '\n\033[1m---------------- %s (%s) ----------------\033[0m\n' "$name" "$type"
  dispatch "$name" "$type" "$osv" "$source" "$size"
  count=$((count+1))
done < <(tsv "$MANIFEST")

printf '\n\033[1m================ SUMMARY ================\033[0m\n'
ok "processed $count image(s). Base dir: $IMAGES_DIR"
say "Log: $LOG"
[ "${DRY_RUN:-0}" = 1 ] && warn "DRY_RUN set - nothing changed."
ls -1 "$IMAGES_DIR" 2>/dev/null | sed 's/^/  /' || true

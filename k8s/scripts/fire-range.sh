#!/usr/bin/env bash
# ONE COMMAND to fire the whole range end-to-end (idempotent).
#
#   ./fire-range.sh [with|without] [--fresh]
#
#   with|without : sinkhole variant to launch (default: with)
#   --fresh      : force a rebuild of all container images
#
# Steps: install k3s+Docker (if missing) -> build images (if missing/--fresh)
#        -> deploy the chosen variant -> show endpoints -> validate.
set -euo pipefail

say()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-sudo k3s kubectl}"

VARIANT=with
FRESH=0
for a in "$@"; do
  case "$a" in
    with|without) VARIANT="$a" ;;
    --fresh)      FRESH=1 ;;
    *) echo "usage: $0 [with|without] [--fresh]"; exit 1 ;;
  esac
done

# 1) cluster
if ! command -v k3s >/dev/null 2>&1; then
  say "k3s not found - installing cluster..."
  "$HERE/01-install-k3s.sh"
else
  ok "k3s present."
fi

# 2) images
need_build=$FRESH
if [ "$need_build" -eq 0 ]; then
  for img in internal-dns external-dns firewall-sim sinkhole infected-pc; do
    sudo k3s ctr -n k8s.io images ls -q | grep -q "${img}:latest" || need_build=1
  done
fi
if [ "$need_build" -eq 1 ]; then
  say "Building images..."
  "$HERE/02-build-images.sh"
else
  ok "All images already present (use --fresh to rebuild)."
fi

# 3) deploy
say "Deploying variant: $VARIANT"
"$HERE/03-deploy.sh" "$VARIANT"

# 4) endpoints
NODEIP="$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[ -z "$NODEIP" ] && NODEIP="<node-ip>"
cat <<EOF

$(ok "Range is LIVE (variant: $VARIANT)")
  Sinkhole dashboard : http://$NODEIP:30080/        (captures + /api/captures)
  Firewall DNS       : dig -p 30053 @$NODEIP <domain>
  internal-dns       : dig -p 30054 @$NODEIP abc.com
  external-dns       : dig -p 30055 @$NODEIP teq.xyz.com
  Switch variant     : ./toggle-variant.sh with|without
  Evidence           : ./validate.sh
EOF

# 5) quick validation
sleep 6
"$HERE/validate.sh" || true

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
  for img in internal-dns external-dns firewall-sim sinkhole infected-pc fake-internet range-console corp-samba-dc corp-web02; do
    sudo k3s ctr -n k8s.io images ls -q | grep -q "${img}:latest" || need_build=1
  done
  for img in postgres:16-alpine mariadb:11.4 nginx:1.27-alpine; do
    sudo k3s ctr -n k8s.io images ls -q | grep -q "library/${img}$" || need_build=1
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
  Range console      : http://$NODEIP:30090/        (login; custom scenarios, logs, captures)
  Sinkhole dashboard : http://$NODEIP:30080/        (captures + /api/captures)
  Fake internet      : http://$NODEIP:30081/        (C2 check-ins + web requests; /api/checkins, /api/requests)
                       in-cluster: fake-c2 10.43.66.66:80, fake-web 10.43.80.80:80
  Firewall DNS       : dig -p 30053 @$NODEIP <domain>
  internal-dns       : dig -p 30054 @$NODEIP abc.com
  external-dns       : dig -p 30055 @$NODEIP teq.xyz.com
  Corp intranet      : http://$NODEIP:30088/        (web01; /app/ = HR portal web02 -> db01/db02)
  Corp servers (ns corp, AD realm CORP.LAB): dc01 dc02 db01 db02 web01 web02 .corp.lab
                       dig -p 30054 @$NODEIP dc01.corp.lab ; creds in ~/.corp-lab-credentials
  Switch variant     : ./toggle-variant.sh with|without
  Evidence           : ./validate.sh
EOF

# 5) quick validation
sleep 6
"$HERE/validate.sh" || true

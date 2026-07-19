#!/usr/bin/env bash
# Switch an already-deployed range between variants WITHOUT rebuilding images.
#   ./toggle-variant.sh with     -> enable sinkhole
#   ./toggle-variant.sh without  -> disable sinkhole
set -euo pipefail

say() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

VARIANT="${1:-}"
case "$VARIANT" in
  with)    CFG="config-with-sinkhole.yaml" ;;
  without) CFG="config-without-sinkhole.yaml" ;;
  *) err "usage: $0 [with|without]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$(cd "$HERE/../manifests" && pwd)"
KUBECTL="${KUBECTL:-sudo k3s kubectl}"

say "Swapping range-mode ConfigMap -> $VARIANT ..."
$KUBECTL apply -f "$M/$CFG"

say "Restarting firewall-sim + infected-pc to pick up new config ..."
$KUBECTL -n cyber-range rollout restart deploy/firewall-sim deploy/infected-pc
$KUBECTL -n cyber-range rollout status  deploy/firewall-sim --timeout=120s
$KUBECTL -n cyber-range rollout status  deploy/infected-pc  --timeout=120s

ok "Now running variant: $VARIANT.  Observe with ./validate.sh"

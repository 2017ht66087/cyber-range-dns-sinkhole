#!/usr/bin/env bash
# Deploy the range and select a variant.
#   ./03-deploy.sh with      -> DNS sinkhole ENABLED  (contained)
#   ./03-deploy.sh without   -> DNS sinkhole DISABLED (uncontained)
set -euo pipefail

say()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

VARIANT="${1:-with}"
case "$VARIANT" in
  with)    CFG="config-with-sinkhole.yaml" ;;
  without) CFG="config-without-sinkhole.yaml" ;;
  *) err "usage: $0 [with|without]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$(cd "$HERE/../manifests" && pwd)"
KUBECTL="${KUBECTL:-sudo k3s kubectl}"

say "Applying namespaces + shared resources ..."
$KUBECTL apply -f "$M/namespace.yaml"
$KUBECTL apply -f "$M/internal-dns.yaml"
$KUBECTL apply -f "$M/external-dns.yaml"
$KUBECTL apply -f "$M/sinkhole.yaml"
$KUBECTL apply -f "$M/networkpolicy.yaml"
$KUBECTL apply -f "$M/nodeport.yaml"

say "Applying range-mode ConfigMap (variant: $VARIANT) ..."
$KUBECTL apply -f "$M/$CFG"

say "Applying firewall-sim + infected-pc ..."
$KUBECTL apply -f "$M/firewall-sim.yaml"
$KUBECTL apply -f "$M/infected-pc.yaml"

# If the deployments already existed, restart them to pick up the ConfigMap.
$KUBECTL -n cyber-range rollout restart deploy/firewall-sim deploy/infected-pc >/dev/null 2>&1 || true

say "Waiting for rollouts ..."
$KUBECTL -n dns-system  rollout status deploy/internal-dns --timeout=120s
$KUBECTL -n dns-system  rollout status deploy/external-dns --timeout=120s
$KUBECTL -n cyber-range rollout status deploy/sinkhole     --timeout=120s
$KUBECTL -n cyber-range rollout status deploy/firewall-sim --timeout=120s
$KUBECTL -n cyber-range rollout status deploy/infected-pc  --timeout=120s

ok "Deployed (variant: $VARIANT)."
$KUBECTL get pods -n cyber-range
$KUBECTL get pods -n dns-system
ok "Watch the exercise:  ./validate.sh"

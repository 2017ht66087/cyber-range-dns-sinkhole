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

say "Applying namespaces ..."
$KUBECTL apply -f "$M/namespace.yaml"

say "Applying range-mode ConfigMaps (variant: $VARIANT) ..."
$KUBECTL apply -f "$M/$CFG"

say "Applying shared resources ..."
$KUBECTL apply -f "$M/internal-dns.yaml"
$KUBECTL apply -f "$M/external-dns.yaml"
$KUBECTL apply -f "$M/sinkhole.yaml"
$KUBECTL apply -f "$M/fake-internet.yaml"
$KUBECTL apply -f "$M/networkpolicy.yaml"
$KUBECTL apply -f "$M/nodeport.yaml"

say "Applying firewall-sim + infected-pc ..."
$KUBECTL apply -f "$M/firewall-sim.yaml"
$KUBECTL apply -f "$M/infected-pc.yaml"

# If the deployments already existed, restart them to pick up the ConfigMaps.
$KUBECTL -n dns-system  rollout restart deploy/internal-dns deploy/external-dns >/dev/null 2>&1 || true
$KUBECTL -n cyber-range rollout restart deploy/firewall-sim deploy/infected-pc >/dev/null 2>&1 || true

say "Applying range console ..."
$KUBECTL apply -f "$M/range-console.yaml"
if ! $KUBECTL -n range-admin get secret console-auth >/dev/null 2>&1; then
  PW_FILE="$HOME/.range-console-initial-password"
  INIT_PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')"
  HASH="$(RC_PW="$INIT_PW" python3 -c 'import hashlib,os,secrets
s=secrets.token_hex(16); i=260000
print("pbkdf2_sha256$%d$%s$%s" % (i, s, hashlib.pbkdf2_hmac("sha256", os.environ["RC_PW"].encode(), bytes.fromhex(s), i).hex()))')"
  $KUBECTL -n range-admin create secret generic console-auth \
    --from-literal=username=admin --from-literal=password_hash="$HASH" >/dev/null
  ( umask 077; printf '%s\n' "$INIT_PW" > "$PW_FILE" )
  ok "Console login created: user 'admin', initial password saved to $PW_FILE (change it in the console's Account tab)."
fi

say "Applying corp servers (2x AD DC, 2x DB, 2x web; namespace corp) ..."
"$HERE/corp-secrets.sh"
$KUBECTL apply -f "$M/corp-servers.yaml"
if [ "${CORP_LATERAL:-0}" = "1" ]; then
  say "CORP_LATERAL=1: opening infected-pc -> corp (lateral-movement surface) ..."
  $KUBECTL apply -f "$M/corp-lateral.yaml"
fi

say "Waiting for rollouts ..."
$KUBECTL -n dns-system  rollout status deploy/internal-dns --timeout=120s
$KUBECTL -n dns-system  rollout status deploy/external-dns --timeout=120s
$KUBECTL -n cyber-range rollout status deploy/sinkhole     --timeout=120s
$KUBECTL -n cyber-range rollout status deploy/firewall-sim --timeout=120s
$KUBECTL -n cyber-range rollout status deploy/infected-pc  --timeout=120s
$KUBECTL -n fake-internet rollout status deploy/fake-internet --timeout=120s
$KUBECTL -n range-admin rollout status deploy/range-console --timeout=120s
# dc01 provisions the domain on first start; dc02 then joins it (a few minutes).
for d in db01 db02 web01 web02 dc01 dc02; do
  $KUBECTL -n corp rollout status deploy/$d --timeout=600s
done

ok "Deployed (variant: $VARIANT)."
$KUBECTL get pods -n cyber-range
$KUBECTL get pods -n dns-system
$KUBECTL get pods -n fake-internet
$KUBECTL get pods -n range-admin
$KUBECTL get pods -n corp
ok "Watch the exercise:  ./validate.sh"

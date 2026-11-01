#!/usr/bin/env bash
# Create the corp lab credentials Secret (namespace corp) with random passwords,
# and keep an operator copy in ~/.corp-lab-credentials (chmod 600).
# Idempotent: an existing Secret is never rotated; the file is re-written from it
# when missing. Rotate with:
#   sudo k3s kubectl -n corp delete secret corp-credentials && ./corp-secrets.sh
# (then delete the corp namespace's PVCs/pods too - the DCs keep the old password).
set -euo pipefail

say() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
NS=corp
SECRET=corp-credentials
CRED_FILE="${CORP_CRED_FILE:-$HOME/.corp-lab-credentials}"
KEYS="ad-admin-password alice-password bob-password svc-sql-password da-test-password
db01-postgres-password db01-web-password db02-root-password db02-web-password"

$KUBECTL create namespace "$NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

if ! $KUBECTL -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  say "Generating random corp lab credentials ..."
  args=()
  for k in $KEYS; do
    # 'Aa1' prefix: AD complexity (upper, lower, digit) and never a leading '-'.
    args+=("--from-literal=$k=$(python3 -c 'import secrets; print("Aa1" + secrets.token_urlsafe(15))')")
  done
  $KUBECTL -n "$NS" create secret generic "$SECRET" "${args[@]}" >/dev/null
  rm -f "$CRED_FILE"
  ok "Secret $NS/$SECRET created."
fi

if [ ! -s "$CRED_FILE" ]; then
  ( umask 077
    {
      echo "# corp.lab cyber-range credentials (from secret $NS/$SECRET) - keep private"
      echo "# AD realm CORP.LAB / domain CORP; AD users: CORP\\<user>; DBs: db01 postgres, db02 mariadb"
      for k in $KEYS; do
        printf '%s=%s\n' "$k" "$($KUBECTL -n "$NS" get secret "$SECRET" -o "jsonpath={.data.$k}" | base64 -d)"
      done
    } > "$CRED_FILE" )
  chmod 600 "$CRED_FILE"
  ok "Credentials copy written to $CRED_FILE (mode 600)."
fi

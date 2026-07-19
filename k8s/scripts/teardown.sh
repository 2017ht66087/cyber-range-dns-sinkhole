#!/usr/bin/env bash
# Remove the range. By default only deletes the workloads/namespaces.
#   ./teardown.sh          -> delete cyber-range + dns-system namespaces
#   ./teardown.sh --nuke   -> also uninstall k3s entirely
set -euo pipefail

say() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

say "Deleting namespaces cyber-range + dns-system ..."
$KUBECTL delete namespace cyber-range --ignore-not-found
$KUBECTL delete namespace dns-system  --ignore-not-found
ok "Range removed."

if [ "${1:-}" = "--nuke" ]; then
  if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
    say "Uninstalling k3s ..."
    sudo /usr/local/bin/k3s-uninstall.sh
    ok "k3s uninstalled."
  else
    echo "k3s-uninstall.sh not found; skipping."
  fi
fi

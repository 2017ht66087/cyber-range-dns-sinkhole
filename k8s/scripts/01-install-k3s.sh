#!/usr/bin/env bash
# Install a single-node k3s cluster + Docker (for building images) on Ubuntu.
# Idempotent: safe to re-run. Run on the Ubuntu guest, not the Windows host.
set -euo pipefail

say()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# --- Docker (image builder) ---
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker (docker.io)..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker.io
  $SUDO systemctl enable --now docker
  $SUDO usermod -aG docker "$USER" || true
  warn "Added $USER to the 'docker' group. Log out/in (or run 'newgrp docker') for it to take effect."
else
  ok "Docker already present: $(docker --version)"
fi

# --- k3s (single node) ---
if ! command -v k3s >/dev/null 2>&1; then
  say "Installing k3s (single-node)..."
  curl -sfL https://get.k3s.io | $SUDO sh -
else
  ok "k3s already present: $(k3s --version | head -1)"
fi

say "Waiting for the node to become Ready..."
for i in $(seq 1 60); do
  if $SUDO k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; then break; fi
  sleep 3
done
$SUDO k3s kubectl get nodes

# Make kubectl usable without sudo for the current user.
say "Exposing kubeconfig at ~/.kube/config ..."
mkdir -p "$HOME/.kube"
$SUDO cat /etc/rancher/k3s/k3s.yaml > "$HOME/.kube/config"
$SUDO chown "$USER:$USER" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

ok "k3s ready. Verify with:  KUBECONFIG=~/.kube/config kubectl get pods -A"
ok "Next: ./02-build-images.sh"

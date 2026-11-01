#!/usr/bin/env bash
# Build the range images (5 range services + fake-internet + range-console + corp servers) with Docker and import them into k3s' containerd
# image store (namespace k8s.io) so the pods can use them with
# imagePullPolicy: IfNotPresent and no external registry.
set -euo pipefail

say()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="$(cd "$HERE/../images" && pwd)"
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# docker may need sudo if the group membership hasn't taken effect yet.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="$SUDO docker"; fi

IMAGES="${IMAGES:-internal-dns external-dns firewall-sim sinkhole infected-pc fake-internet range-console corp-samba-dc corp-web02}"
# Public images used by the corp servers (manifests/corp-servers.yaml), pre-pulled
# so the range runs without internet afterwards. Skip with PULL_IMAGES="".
PULL_IMAGES="${PULL_IMAGES-postgres:16-alpine mariadb:11.4 nginx:1.27-alpine}"

for name in $IMAGES; do
  say "Building $name:latest ..."
  $DOCKER build -t "$name:latest" "$IMG_DIR/$name"
  say "Importing $name:latest into k3s containerd ..."
  $DOCKER save "$name:latest" | $SUDO k3s ctr -n k8s.io images import -
  ok "$name:latest ready in k3s"
done

for ref in $PULL_IMAGES; do
  say "Pulling $ref into k3s containerd ..."
  $SUDO k3s crictl pull "docker.io/library/$ref" >/dev/null
  ok "$ref ready in k3s"
done

ok "All images built + imported. Verify:  sudo k3s ctr -n k8s.io images ls | grep -E 'internal-dns|external-dns|firewall-sim|sinkhole|infected-pc|fake-internet|range-console'"
ok "Next: ./03-deploy.sh with   (or: without)"

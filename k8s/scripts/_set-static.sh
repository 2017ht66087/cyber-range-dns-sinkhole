#!/usr/bin/env bash
# Give the range VM a STATIC IP and retarget k3s to it. The network switch is
# scheduled in the background so it survives the SSH disconnect it causes.
set -e
IFACE=ens160
STATIC=192.168.9.50
GW=192.168.9.2

# --- static netplan (replace cloud-init's DHCP config) ---
sudo tee /etc/netplan/50-cloud-init.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${STATIC}/24]
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses: [${GW}, 1.1.1.1]
EOF
sudo chmod 600 /etc/netplan/50-cloud-init.yaml

# stop cloud-init from regenerating DHCP net config on next boot
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null

# --- point k3s at the static node IP ---
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
node-ip: ${STATIC}
flannel-iface: ${IFACE}
EOF

# --- persist IP forwarding so the host can route to pod/service CIDRs ---
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-k8s-forward.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-k8s-forward.conf >/dev/null

sudo netplan generate

# apply AFTER this session returns (network flip kills the current SSH link)
sudo nohup bash -c 'sleep 3; netplan apply; sleep 6; systemctl restart k3s' >/tmp/set-static.log 2>&1 &
echo SCHEDULED_APPLY

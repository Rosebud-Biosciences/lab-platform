#!/bin/bash
set -euo pipefail

# Admin access is via AWS SSM Session Manager (no SSH). Canonical Ubuntu AMIs
# ship the SSM agent as a snap; make sure it is running.
sudo snap start amazon-ssm-agent || true

# install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# enable ip forwarding (required for subnet routing)
# https://tailscale.com/kb/1019/subnets/?tab=linux#enable-ip-forwarding
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

# run Tailscale as a subnet router
# https://tailscale.com/kb/1021/install-aws/
# https://tailscale.com/kb/1019/subnets/
sudo systemctl enable --now tailscaled
sudo tailscale up --hostname ${name} --authkey ${tailscale_auth_key} --advertise-routes=${subnet_routes} --accept-dns=false

# keep the client patched automatically
sudo tailscale set --auto-update

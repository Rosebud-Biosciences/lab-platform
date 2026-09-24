#!/bin/bash
set -euo pipefail

# Admin access is via AWS SSM Session Manager (no SSH). Canonical Ubuntu AMIs
# ship the SSM agent as a snap; make sure it is running.
sudo snap start amazon-ssm-agent || true

# install Tailscale -- retried, because a failure here stops the script
# (set -e) before `tailscale up`, and the relay never joins the tailnet
for attempt in $(seq 1 30); do
  if curl -fsSL https://tailscale.com/install.sh | sh; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    echo "tailscale install failed 30 times; giving up" >&2
    exit 1
  fi
  sleep 10
done

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

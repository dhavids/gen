#!/bin/bash
# ==============================================================================
# Client-side setup script — reverse SSH tunnel from a client machine to a VPS,
# for exposing a local web app (e.g. Guacamole) publicly without relying on a
# mesh VPN (Tailscale/etc.) for that specific traffic.
#
# Run this on the CLIENT machine (the one running the local service you want
# to expose), as the normal user — uses sudo where needed.
#
# PREREQUISITES (must be done manually BEFORE running this script):
#   1. The VPS is already set up (vps-setup.sh has been run there)
#   2. You know the VPS's IP or hostname
#
# USAGE:
#   VPS_HOST=203.0.113.10 VPS_USER=tunnel GUAC_LOCAL_PORT=8080 \
#   bash client-tunnel-setup.sh
# ==============================================================================
set -euo pipefail

VPS_HOST="${VPS_HOST:?Set VPS_HOST, e.g. 203.0.113.10 or vpn.example.com}"
VPS_USER="${VPS_USER:-tunnel}"
GUAC_LOCAL_PORT="${GUAC_LOCAL_PORT:-8080}"      # local service's port on this client machine
GUAC_TUNNEL_PORT="${GUAC_TUNNEL_PORT:-9000}"    # matches GUAC_TUNNEL_PORT in vps-setup.sh
KEY_PATH="${KEY_PATH:-$HOME/.ssh/vps_tunnel}"

echo "=== Config ==="
echo "VPS_HOST=$VPS_HOST  VPS_USER=$VPS_USER  GUAC_LOCAL_PORT=$GUAC_LOCAL_PORT  GUAC_TUNNEL_PORT=$GUAC_TUNNEL_PORT"
echo ""

# ---- 1. Generate a dedicated tunnel key if it doesn't exist ------------------

echo "=== [1/4] SSH key ==="
if [ ! -f "$KEY_PATH" ]; then
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""
  echo "Generated new key at $KEY_PATH"
  echo "Now run: ssh-copy-id -i ${KEY_PATH}.pub $VPS_USER@$VPS_HOST"
  echo "(requires password auth to be enabled once, or manually add the .pub to the VPS's authorized_keys)"
  read -rp "Press enter once the key has been authorized on the VPS..."
else
  echo "Key already exists at $KEY_PATH, skipping generation."
fi

# ---- 2. Clear any stale host key (relevant on VPS migration) ----------------

echo "=== [2/4] Clearing stale SSH host key for $VPS_HOST (if any) ==="
ssh-keygen -R "$VPS_HOST" 2>/dev/null || true

# ---- 3. Test connection ------------------------------------------------------

echo "=== [3/4] Testing SSH connection ==="
if ssh -o StrictHostKeyChecking=accept-new -i "$KEY_PATH" "$VPS_USER@$VPS_HOST" "echo tunnel key works"; then
  echo "SSH connection OK."
else
  echo "SSH connection FAILED. Fix this before continuing (check key authorization on VPS)."
  exit 1
fi

# ---- 4. Install autossh + systemd service ------------------------------------

echo "=== [4/4] Installing autossh service ==="
sudo apt install -y autossh

CURRENT_USER="$(whoami)"
HOME_DIR="$HOME"

sudo tee /etc/systemd/system/vps-tunnel.service > /dev/null << EOF
[Unit]
Description=Reverse tunnel to VPS for Guacamole
After=network-online.target

[Service]
ExecStart=/usr/bin/autossh -M 0 -N -R 127.0.0.1:${GUAC_TUNNEL_PORT}:127.0.0.1:${GUAC_LOCAL_PORT} -i ${KEY_PATH} ${VPS_USER}@${VPS_HOST} -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" -o "StrictHostKeyChecking accept-new"
Restart=always
RestartSec=5
User=${CURRENT_USER}

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now vps-tunnel
sleep 2
sudo systemctl status vps-tunnel --no-pager

echo ""
echo "=== Done. Now, from the VPS, verify: ==="
echo "  sudo ss -tlnp | grep $GUAC_TUNNEL_PORT"
echo "  curl -I http://127.0.0.1:${GUAC_TUNNEL_PORT}/guacamole/"
#!/bin/bash
# ==============================================================================
# Client-side setup script — reverse SSH tunnel from a client machine to a VPS,
# for exposing a local web app (e.g. Guacamole) publicly via Cloudflare Tunnel
# without relying on a mesh VPN (Tailscale/etc.) for that specific traffic.
#
# Run this on the CLIENT machine (the one running the local service you want
# to expose), as the normal user — uses sudo where needed.
#
# WHAT THIS SCRIPT CANNOT DO FOR YOU:
#   - The very first authorization of your SSH key on the VPS. If the key
#     isn't already in the VPS user's authorized_keys, this script will
#     PAUSE and tell you exactly what command to run (needs the VPS
#     account's password, or manual authorized_keys placement).
#
# USAGE:
#   bash client.sh \
#     --vps-host 203.0.113.10 \
#     --vps-user tunnel \
#     --guac-local-port 8080
#
# Run with --help for the full flag list.
# ==============================================================================
set -euo pipefail

# ---- Defaults ------------------------------------------------------------------
VPS_HOST=""
VPS_USER="tunnel"
GUAC_LOCAL_PORT="8080"
GUAC_TUNNEL_PORT="9000"     # must match --guac-tunnel-port used in server.sh
KEY_PATH="$HOME/.ssh/vps_tunnel"

usage() {
  cat << 'USAGE'
Usage: bash client.sh --vps-host HOST [options]

Required:
  --vps-host HOST            VPS IP or hostname, e.g. 203.0.113.10

Optional:
  --vps-user USER            SSH user on the VPS (default: tunnel)
  --guac-local-port PORT     Local service's port on THIS machine (default: 8080)
  --guac-tunnel-port PORT    Port on the VPS the tunnel forwards to — must match
                             --guac-tunnel-port used in server.sh (default: 9000)
  --key-path PATH            Path for the dedicated SSH key (default: ~/.ssh/vps_tunnel)
  -h, --help                 Show this help and exit
USAGE
}

# ---- Flag parsing ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --vps-host) VPS_HOST="$2"; shift 2 ;;
    --vps-user) VPS_USER="$2"; shift 2 ;;
    --guac-local-port) GUAC_LOCAL_PORT="$2"; shift 2 ;;
    --guac-tunnel-port) GUAC_TUNNEL_PORT="$2"; shift 2 ;;
    --key-path) KEY_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$VPS_HOST" ]; then
  echo "ERROR: --vps-host is required." >&2
  usage
  exit 1
fi

echo "=== Config ==="
echo "VPS_HOST=$VPS_HOST  VPS_USER=$VPS_USER  GUAC_LOCAL_PORT=$GUAC_LOCAL_PORT  GUAC_TUNNEL_PORT=$GUAC_TUNNEL_PORT"
echo ""


# ---- 1. SSH key -------------------------------------------------------------------

echo "=== [1/4] SSH key ==="
if [ ! -f "$KEY_PATH" ]; then
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""
  echo "Generated new key at $KEY_PATH"
else
  echo "Key already exists at $KEY_PATH, reusing it."
fi

# Check whether the key is already authorized before bothering the user
if ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$KEY_PATH" "$VPS_USER@$VPS_HOST" "echo ok" &>/dev/null; then
  echo "Key is already authorized on the VPS."
else
  echo ""
  echo "=========================================================================="
  echo "  MANUAL STEP REQUIRED: Authorize this key on the VPS"
  echo "=========================================================================="
  echo "  Run this now, from this machine, in another terminal (or right after"
  echo "  this prompt — it'll ask for the $VPS_USER account's password on the VPS):"
  echo ""
  echo "      ssh-copy-id -i ${KEY_PATH}.pub $VPS_USER@$VPS_HOST"
  echo ""
  echo "  If ssh-copy-id isn't available, use this instead:"
  echo "      cat ${KEY_PATH}.pub | ssh $VPS_USER@$VPS_HOST \\"
  echo "        \"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys\""
  echo "=========================================================================="
  read -rp "Press Enter once the key is authorized, to continue the script... "
fi


# ---- 2. Clear stale host key (relevant on VPS migration) --------------------------

echo "=== [2/4] Clearing stale SSH host key for $VPS_HOST (if any) ==="
ssh-keygen -R "$VPS_HOST" 2>/dev/null || true


# ---- 3. Test connection ------------------------------------------------------------

echo "=== [3/4] Testing SSH connection ==="
if ssh -o StrictHostKeyChecking=accept-new -i "$KEY_PATH" "$VPS_USER@$VPS_HOST" "echo tunnel key works"; then
  echo "SSH connection OK."
else
  echo "SSH connection FAILED. Fix this before continuing (check key authorization on VPS)." >&2
  exit 1
fi


# ---- 4. Install autossh + systemd service -------------------------------------------

echo "=== [4/4] Installing autossh service ==="
sudo apt install -y autossh

CURRENT_USER="$(whoami)"

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
echo ""
echo "And publicly, from a browser (curl may be blocked by Cloudflare bot"
echo "protection even when it's working — a browser test is more reliable):"
echo "  https://<your-guac-host>/guacamole/"
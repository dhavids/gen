#!/bin/bash
# ==============================================================================
# VPS setup script — derper + Caddy(layer4) + certbot
# Run this AS ROOT (or via sudo) on a fresh Ubuntu 24.04 droplet.
#
# PREREQUISITES (must be done manually BEFORE running this script):
#   1. DNS A records for DERP_HOST and GUAC_HOST already point at this VPS's IP
#      and have propagated (check: dig +short $DERP_HOST @8.8.8.8)
#   2. You have a real email address for Let's Encrypt notices
#
# USAGE:
#   sudo DOMAIN=example.com \
#        EMAIL=you@example.com TUNNEL_USER=tunnel \
#        TUNNEL_USER_PASSWORD=some-strong-password \
#        bash vps-setup.sh
#
# This derives DERP_HOST=derp.$DOMAIN and GUAC_HOST=guac.$DOMAIN automatically.
# If you need different subdomain names, override DERP_HOST/GUAC_HOST directly
# instead of (or alongside) DOMAIN.
#
# TUNNEL_USER_PASSWORD is OPTIONAL. Leave it unset if TUNNEL_USER should only
# ever be used for the automated SSH tunnel (key-auth only, no sudo — the
# more secure default). Set it if you also want to log in interactively as
# this user and run sudo commands for day-to-day admin.
# ==============================================================================
set -euo pipefail

# ---- Config (override via env vars, or edit these defaults) ----------------

DOMAIN="${DOMAIN:-}"
DERP_HOST="${DERP_HOST:-derp.${DOMAIN}}"
GUAC_HOST="${GUAC_HOST:-guac.${DOMAIN}}"

if [ "$DERP_HOST" = "derp." ] || [ "$GUAC_HOST" = "guac." ]; then
  echo "ERROR: Set DOMAIN=example.com, or set DERP_HOST and GUAC_HOST directly." >&2
  exit 1
fi

EMAIL="${EMAIL:?Set EMAIL for Lets Encrypt notices}"
TUNNEL_USER="${TUNNEL_USER:-tunnel}"
TUNNEL_USER_PASSWORD="${TUNNEL_USER_PASSWORD:-}"   # optional: set to allow sudo+password login for this user
GUAC_TUNNEL_PORT="${GUAC_TUNNEL_PORT:-9000}"   # port autossh from the client forwards to
CADDY_INTERNAL_PORT="${CADDY_INTERNAL_PORT:-8081}"
DERPER_PORT="${DERPER_PORT:-8443}"

echo "=== Config ==="
echo "DERP_HOST=$DERP_HOST  GUAC_HOST=$GUAC_HOST  EMAIL=$EMAIL  TUNNEL_USER=$TUNNEL_USER"
if [ -n "$TUNNEL_USER_PASSWORD" ]; then
  echo "TUNNEL_USER_PASSWORD: set (sudo + password login enabled for $TUNNEL_USER)"
else
  echo "TUNNEL_USER_PASSWORD: not set ($TUNNEL_USER will be SSH-key-only, no sudo)"
fi
echo ""

# ---- 1. Basic hardening -----------------------------------------------------

echo "=== [1/8] Hardening ==="
echo ""
apt update && apt upgrade -y

if ! id "$TUNNEL_USER" &>/dev/null; then
  if [ -n "$TUNNEL_USER_PASSWORD" ]; then
    # Password provided: this account is also meant for interactive admin
    # login (matches typical usage — logging in as this user and using
    # sudo for day-to-day server work), so give it sudo + a real password.
    adduser --gecos "" --disabled-password "$TUNNEL_USER"
    echo "${TUNNEL_USER}:${TUNNEL_USER_PASSWORD}" | chpasswd
    usermod -aG sudo "$TUNNEL_USER"
  else
    # No password provided: this account exists solely to accept the
    # incoming SSH tunnel from the client machine (key-auth only). It
    # never needs to run privileged commands, so no sudo group either.
    adduser --disabled-password --gecos "" "$TUNNEL_USER"
    echo "NOTE: $TUNNEL_USER created with no password and no sudo access (SSH-key-only)."
    echo "      Set TUNNEL_USER_PASSWORD if you also want to use this account for admin/sudo login."
  fi
  if [ -d /root/.ssh ]; then
    rsync --archive --chown="$TUNNEL_USER:$TUNNEL_USER" /root/.ssh "/home/$TUNNEL_USER/"
  fi
fi

ufw allow OpenSSH
ufw allow 443/tcp
ufw allow 80/tcp
ufw allow 3478/udp
ufw --force enable

apt install -y unattended-upgrades fail2ban
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades || true

# ---- 2. Install derper -------------------------------------------------------

echo "=== [2/8] Installing derper ==="
echo ""
apt install -y golang-go git certbot

export GOPATH=/root/go
export PATH=$PATH:/root/go/bin
go install tailscale.com/cmd/derper@latest
cp /root/go/bin/derper /usr/local/bin/derper
mkdir -p /var/lib/derper/certs

# ---- 3. Get certs (standalone, port 80 must be free) ------------------------

echo "=== [3/8] Obtaining certs via certbot standalone ==="
echo ""
# make sure nothing is on 80 yet
systemctl stop caddy 2>/dev/null || true

certbot certonly --standalone -d "$DERP_HOST" \
  --preferred-challenges http -m "$EMAIL" --agree-tos --non-interactive

certbot certonly --standalone -d "$GUAC_HOST" \
  --preferred-challenges http -m "$EMAIL" --agree-tos --non-interactive

cp "/etc/letsencrypt/live/$DERP_HOST/fullchain.pem" "/var/lib/derper/certs/$DERP_HOST.crt"
cp "/etc/letsencrypt/live/$DERP_HOST/privkey.pem" "/var/lib/derper/certs/$DERP_HOST.key"

# ---- 4. derper systemd service ----------------------------------------------

echo "=== [4/8] Creating derper systemd service ==="
echo ""
cat > /etc/systemd/system/derper.service << EOF
[Unit]
Description=Tailscale DERP server
After=network.target

[Service]
ExecStart=/usr/local/bin/derper \\
  --hostname=$DERP_HOST \\
  --certmode=manual \\
  --certdir=/var/lib/derper/certs \\
  --a=:$DERPER_PORT \\
  --http-port=-1 \\
  --stun-port=3478
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now derper

# ---- 5. Build Caddy with layer4 ---------------------------------------------

echo "=== [5/8] Building Caddy with layer4 plugin ==="
echo ""
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
/root/go/bin/xcaddy build --with github.com/mholt/caddy-l4
mv ./caddy /usr/local/bin/caddy

# ---- 6. Caddyfile + systemd --------------------------------------------------

echo "=== [6/8] Writing Caddyfile ==="
echo ""
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile << EOF
{
	auto_https off

	layer4 {
		:443 {
			@derp tls sni $DERP_HOST
			route @derp {
				proxy 127.0.0.1:$DERPER_PORT
			}

			@guac tls sni $GUAC_HOST
			route @guac {
				proxy 127.0.0.1:$CADDY_INTERNAL_PORT
			}
		}
	}
}

:$CADDY_INTERNAL_PORT {
	tls /etc/letsencrypt/live/$GUAC_HOST/fullchain.pem /etc/letsencrypt/live/$GUAC_HOST/privkey.pem
	reverse_proxy 127.0.0.1:$GUAC_TUNNEL_PORT
}
EOF

caddy validate --config /etc/caddy/Caddyfile

cat > /etc/systemd/system/caddy.service << EOF
[Unit]
Description=Caddy (layer4 build)
After=network.target

[Service]
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now caddy

# ---- 7. Renewal hook ----------------------------------------------------------

echo "=== [7/8] Setting up cert renewal hook ==="
echo ""
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/caddy-reload.sh << EOF
#!/bin/bash
cp /etc/letsencrypt/live/$DERP_HOST/fullchain.pem /var/lib/derper/certs/$DERP_HOST.crt
cp /etc/letsencrypt/live/$DERP_HOST/privkey.pem /var/lib/derper/certs/$DERP_HOST.key
systemctl restart derper
systemctl restart caddy
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/caddy-reload.sh

# ---- 8. Verify ------------------------------------------------------------

echo "=== [8/8] Verification ==="
echo ""
sleep 2
echo "--- derper status ---"
systemctl is-active derper
echo "--- caddy status ---"
systemctl is-active caddy
echo "--- local curl test ---"
curl -sI "https://$DERP_HOST/" || echo "derp curl failed (check DNS/propagation)"
echo ""
echo "=== Done. Now:"
echo "  1. Confirm from a DIFFERENT machine (not this VPS): curl -I https://$DERP_HOST/"
echo "  2. Add the derpMap block to Tailscale ACLs (see main guide) if not already done"
echo "  3. Run client-tunnel-setup.sh on your client machine, pointing at this VPS's IP"
echo "  4. Test 'sudo certbot renew --dry-run' to confirm renewal works"
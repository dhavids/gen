#!/bin/bash
# ==============================================================================
# VPS setup script — derper (Tailscale DERP relay) + Cloudflare Tunnel,
# fronting both the DERP relay and a tunneled local web app (e.g. Guacamole)
# without exposing the VPS's IP directly on port 443.
#
# Run this AS ROOT (or via sudo) on a fresh Ubuntu 24.04 droplet.
#
# WHY THIS ARCHITECTURE:
#   Exposing a VPS's raw IP on port 443 can get silently blocked by
#   destination/category-based filtering on restrictive networks (e.g. a
#   "newly registered domain" filtering category — very common on managed
#   networks). Routing through Cloudflare Tunnel means public traffic hits
#   Cloudflare's shared edge (used by a huge share of the internet — not
#   something most networks can block wholesale), which relays it to this
#   VPS over an OUTBOUND-ONLY connection. No inbound port 443 needed at all.
#
# WHAT THIS SCRIPT DOES AUTOMATICALLY:
#   - Basic VPS hardening (dedicated user, ufw, fail2ban, auto-updates)
#   - Installs derper and gets it a real cert via certbot (standalone)
#   - Installs cloudflared and writes its config
#   - Sets up systemd services + cert renewal hook
#
# WHAT THIS SCRIPT CANNOT DO FOR YOU (needs a browser / your own account):
#   - Creating a Cloudflare account and adding your domain to it
#   - Changing your domain's nameservers at your registrar to Cloudflare's
#   - Authorizing this VPS against your Cloudflare account (`cloudflared
#     tunnel login` opens a URL you must open in a browser and approve)
#   - Adding the custom DERP region to your Tailscale ACL policy
#   The script will PAUSE and print exact instructions at each such point,
#   and wait for you to press Enter once you've done it.
#
# RUNNING ONLY SOME STEPS:
#   Use --steps to run a subset, e.g. to just (re-)harden an existing VPS:
#     sudo bash server.sh --steps hardening
#   Comma-separate multiple steps: --steps hardening,derper-build
#   You can also use BUNDLES that expand to several steps at once:
#     derper      -> derper-build, derper-cert, derper-service
#     cloudflare  -> cloudflare-account, cloudflared-install, cloudflared-auth, cloudflared-config
#     renew       -> renewal-hook, verify
#   e.g.: --steps derper,cloudflare
#   Run --list-steps to see all step and bundle names. Default is "all".
#
# USAGE:
#   sudo bash server.sh \
#     --domain example.com \
#     --email you@example.com \
#     [--tunnel-user tunnel] \
#     [--tunnel-user-password 'some-strong-password'] \
#     [--guac-tunnel-port 9000] \
#     [--derper-port 8443] \
#     [--steps all]
#
# Run with --help for the full flag list.
# ==============================================================================
set -euo pipefail

# ---- Defaults ----------------------------------------------------------------
DOMAIN=""
DERP_HOST=""
GUAC_HOST=""
EMAIL=""
TUNNEL_USER="tunnel"
TUNNEL_USER_PASSWORD=""
GUAC_TUNNEL_PORT="9000"
DERPER_PORT="8443"
CF_TUNNEL_NAME="vps-tunnel"
STEPS="all"

ALL_STEPS="cloudflare-account hardening ssh-harden derper-build derper-cert derper-service cloudflared-install cloudflared-auth cloudflared-config renewal-hook verify tailscale-acl"

declare -A BUNDLES=(
  [derper]="derper-build derper-cert derper-service"
  [cloudflare]="cloudflare-account cloudflared-install cloudflared-auth cloudflared-config"
  [renew]="renewal-hook verify"
)

usage() {
  cat << 'USAGE'
Usage: sudo bash server.sh --domain DOMAIN --email EMAIL [options]

Required (only for the specific steps that need them — see --list-steps):
  --domain DOMAIN                Base domain, e.g. example.com
                                  (derives derp.DOMAIN and guac.DOMAIN)
  --email EMAIL                  Real email address for Let's Encrypt notices
                                  (only needed for the derper-cert step)

Optional:
  --derp-host HOST                Override the derived derp.DOMAIN
  --guac-host HOST                Override the derived guac.DOMAIN
  --tunnel-user NAME               System user for the SSH tunnel account (default: tunnel)
  --tunnel-user-password PASSWORD  Set to also allow this user sudo + password login
                                    (default: unset — key-auth only, no sudo, more secure)
  --guac-tunnel-port PORT          Local port the client's SSH tunnel forwards to (default: 9000)
  --derper-port PORT               Internal port derper listens on (default: 8443)
  --cf-tunnel-name NAME             Name for the Cloudflare Tunnel (default: vps-tunnel)
  --steps STEP1,STEP2,...          Only run these steps or bundles (default: all). See --list-steps.
  --list-steps                     Print available steps and bundles and exit
  -h, --help                       Show this help and exit

NOTE: --domain/--email are only required if a selected step actually needs
them (e.g. "hardening" alone needs neither). The script fails fast, before
doing anything, listing exactly which flag is missing for which step.
USAGE
}

list_steps() {
  echo "Individual steps (run in this order when --steps=all):"
  echo "  cloudflare-account   Manual: Cloudflare account + domain onboarding"
  echo "  hardening            User account, ufw, fail2ban, auto-updates"
  echo "  ssh-harden           Manual: disable root login + password auth"
  echo "  derper-build          Install the derper binary"
  echo "  derper-cert           Get derper's cert via certbot standalone"
  echo "  derper-service        Write + start derper's systemd service"
  echo "  cloudflared-install   Install the cloudflared package"
  echo "  cloudflared-auth      Manual: cloudflared tunnel login"
  echo "  cloudflared-config    Create tunnel, config, DNS routes, systemd service"
  echo "  renewal-hook          Cert renewal hook for derper"
  echo "  verify                Status checks + local curl test"
  echo "  tailscale-acl         Manual: print the derpMap ACL block to add"
  echo ""
  echo "Bundles (expand to several steps at once):"
  echo "  derper      -> derper-build, derper-cert, derper-service"
  echo "  cloudflare  -> cloudflare-account, cloudflared-install, cloudflared-auth, cloudflared-config"
  echo "  renew       -> renewal-hook, verify"
  echo ""
  echo "Example: sudo bash server.sh --steps hardening"
  echo "Example: sudo bash server.sh --domain example.com --email you@example.com --steps derper"
  echo "Example: sudo bash server.sh --domain example.com --steps cloudflare"
  echo "Example: sudo bash server.sh --domain example.com --steps renew"
}

# ---- Flag parsing --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --derp-host) DERP_HOST="$2"; shift 2 ;;
    --guac-host) GUAC_HOST="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --tunnel-user) TUNNEL_USER="$2"; shift 2 ;;
    --tunnel-user-password) TUNNEL_USER_PASSWORD="$2"; shift 2 ;;
    --guac-tunnel-port) GUAC_TUNNEL_PORT="$2"; shift 2 ;;
    --derper-port) DERPER_PORT="$2"; shift 2 ;;
    --cf-tunnel-name) CF_TUNNEL_NAME="$2"; shift 2 ;;
    --steps) STEPS="$2"; shift 2 ;;
    --list-steps) list_steps; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 1 ;;
  esac
done

[ -z "$DERP_HOST" ] && [ -n "$DOMAIN" ] && DERP_HOST="derp.${DOMAIN}"
[ -z "$GUAC_HOST" ] && [ -n "$DOMAIN" ] && GUAC_HOST="guac.${DOMAIN}"

# ---- Expand --steps into a flat, deduplicated list of individual steps -------
if [ "$STEPS" = "all" ]; then
  RUN_STEPS="$ALL_STEPS"
else
  RAW_TOKENS="$(echo "$STEPS" | tr ',' ' ')"
  EXPANDED=""
  for tok in $RAW_TOKENS; do
    if [ -n "${BUNDLES[$tok]:-}" ]; then
      EXPANDED="$EXPANDED ${BUNDLES[$tok]}"
    else
      case " $ALL_STEPS " in
        *" $tok "*) EXPANDED="$EXPANDED $tok" ;;
        *) echo "ERROR: unknown step or bundle '$tok'. Run --list-steps to see valid names." >&2; exit 1 ;;
      esac
    fi
  done
  # dedupe while preserving order
  RUN_STEPS=""
  for s in $EXPANDED; do
    case " $RUN_STEPS " in
      *" $s "*) : ;;
      *) RUN_STEPS="$RUN_STEPS $s" ;;
    esac
  done
  RUN_STEPS="$(echo "$RUN_STEPS" | xargs)"
fi

should_run() {
  case " $RUN_STEPS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- Per-step flag requirements: fail early, before doing anything, if a
# selected step needs a flag that wasn't passed. Steps not listed here have
# no hard requirements (they only use flags with defaults, e.g. --tunnel-user).
declare -A STEP_NEEDS_HOST=(
  [cloudflare-account]=1 [derper-cert]=1 [derper-service]=1
  [cloudflared-auth]=1 [cloudflared-config]=1 [renewal-hook]=1
  [verify]=1 [tailscale-acl]=1
)
declare -A STEP_NEEDS_EMAIL=(
  [derper-cert]=1
)

MISSING=""
for s in $RUN_STEPS; do
  if [ "${STEP_NEEDS_HOST[$s]:-}" = "1" ] && { [ -z "$DERP_HOST" ] || [ -z "$GUAC_HOST" ]; }; then
    MISSING="${MISSING}  step '$s' needs --domain (or both --derp-host and --guac-host)\n"
  fi
  if [ "${STEP_NEEDS_EMAIL[$s]:-}" = "1" ] && [ -z "$EMAIL" ]; then
    MISSING="${MISSING}  step '$s' needs --email\n"
  fi
done

if [ -n "$MISSING" ]; then
  echo "ERROR: missing required flags for the steps you selected:" >&2
  echo -e "$MISSING" >&2
  exit 1
fi

# ---- Helper: pause for a manual step ------------------------------------------
manual_step() {
  local title="$1"
  shift
  echo ""
  echo "=========================================================================="
  echo "  MANUAL STEP REQUIRED: $title"
  echo "=========================================================================="
  for line in "$@"; do
    echo "  $line"
  done
  echo "=========================================================================="
  read -rp "Press Enter once this step is done, to continue the script... "
  echo ""
}

echo "=== Config ==="
echo "DERP_HOST=${DERP_HOST:-<not set>}  GUAC_HOST=${GUAC_HOST:-<not set>}  EMAIL=${EMAIL:-<not set>}  TUNNEL_USER=$TUNNEL_USER"
if [ -n "$TUNNEL_USER_PASSWORD" ]; then
  echo "TUNNEL_USER_PASSWORD: set (sudo + password login enabled for $TUNNEL_USER)"
else
  echo "TUNNEL_USER_PASSWORD: not set ($TUNNEL_USER will be SSH-key-only, no sudo)"
fi
echo "Steps to run: $RUN_STEPS"
echo ""


# ==== Step: cloudflare-account ===================================================

step_cloudflare_account() {

manual_step "Cloudflare account and domain setup" \
  "1. Sign up at https://dash.cloudflare.com/sign-up (skip if you already have an account)" \
  "2. Add your domain ($DOMAIN) as a site in Cloudflare" \
  "3. Cloudflare will show you two nameservers (e.g. xxx.ns.cloudflare.com)" \
  "4. Go to your domain registrar and change the domain's nameservers to those two" \
  "5. Wait for Cloudflare's dashboard to show the zone as 'Active' (can take a while to propagate)" \
  "6. IMPORTANT: go to Speed -> Settings and turn OFF 'HTTP/3 (with QUIC)' for this zone." \
  "   Without this, WebSocket connections (e.g. Guacamole) can fail or drop randomly on" \
  "   networks where QUIC/UDP is unreliable, even though the tunnel itself is fine —" \
  "   the browser negotiates HTTP/3 with Cloudflare's edge independently of anything" \
  "   cloudflared does, so this has to be turned off at the zone level, not in config.yml."

}


# ==== Step: hardening =============================================================

step_hardening() {

echo "=== Hardening ==="
echo ""
apt update && apt upgrade -y

if ! id "$TUNNEL_USER" &>/dev/null; then
  if [ -n "$TUNNEL_USER_PASSWORD" ]; then
    adduser --gecos "" --disabled-password "$TUNNEL_USER"
    echo "${TUNNEL_USER}:${TUNNEL_USER_PASSWORD}" | chpasswd
    usermod -aG sudo "$TUNNEL_USER"
  else
    adduser --disabled-password --gecos "" "$TUNNEL_USER"
    echo "NOTE: $TUNNEL_USER created with no password and no sudo access (SSH-key-only)."
    echo "      Pass --tunnel-user-password if you also want admin/sudo login as this user."
  fi
  if [ -d /root/.ssh ]; then
    rsync --archive --chown="$TUNNEL_USER:$TUNNEL_USER" /root/.ssh "/home/$TUNNEL_USER/"
  fi
else
  echo "User $TUNNEL_USER already exists, skipping creation."
fi

# NOTE ON FIREWALL: unlike a direct-exposure setup, this VPS does NOT need
# inbound 443 open to the public — Cloudflare Tunnel makes only OUTBOUND
# connections from this VPS. We keep:
#   - SSH (22): admin access + the client's reverse tunnel
#   - UDP 3478 (STUN): Tailscale's direct-connection probing talks to this
#     VPS's real IP directly (Cloudflare doesn't proxy raw UDP/STUN), so this
#     needs to stay open publicly for DERP's STUN feature to work at all.
#   - TCP 80: only needed transiently when certbot issues/renews derper's cert.
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 3478/udp
ufw --force enable

apt install -y unattended-upgrades fail2ban
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades || true

}


# ==== Step: ssh-harden =============================================================

step_ssh_harden() {

echo "=== SSH Hardening ==="
echo ""
echo "About to edit /etc/ssh/sshd_config to set:"
echo "  PermitRootLogin no"
echo "  PasswordAuthentication no"
echo "  PubkeyAuthentication yes"
echo ""
echo "A timestamped backup of the current file will be kept first."
read -rp "Proceed with this edit? [y/N] " confirm_edit
if [[ ! "$confirm_edit" =~ ^[Yy]$ ]]; then
  echo "Skipped SSH hardening — no changes made."
  return
fi

cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"

for pair in "PermitRootLogin:no" "PasswordAuthentication:no" "PubkeyAuthentication:yes"; do
  key="${pair%%:*}"
  val="${pair##*:}"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" /etc/ssh/sshd_config; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" /etc/ssh/sshd_config
  else
    echo "${key} ${val}" >> /etc/ssh/sshd_config
  fi
done

echo ""
echo "Edited /etc/ssh/sshd_config. Current relevant lines:"
grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)" /etc/ssh/sshd_config
echo ""

read -rp "Restart SSH now to apply these changes? [y/N] " confirm_restart
if [[ ! "$confirm_restart" =~ ^[Yy]$ ]]; then
  echo "NOTE: changes are written to sshd_config but NOT active yet (SSH not restarted)."
  return
fi

systemctl restart ssh
echo "SSH restarted."
echo ""

echo "Attempting an automated local login check as $TUNNEL_USER (best-effort)..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$TUNNEL_USER@localhost" "echo ok" &>/dev/null; then
  echo "Automated check succeeded: $TUNNEL_USER can log in with a key over SSH."
else
  echo "NOTE: automated local check didn't succeed — this can be normal (e.g. no agent"
  echo "      forwarding set up on this box) and isn't necessarily a problem. The manual"
  echo "      check below is the one that actually matters."
fi

echo ""
echo "=========================================================================="
echo "  BEFORE CONTINUING: open a SECOND terminal now (don't close this one) and"
echo "  confirm you can still log in as $TUNNEL_USER with your key:"
echo "      ssh $TUNNEL_USER@<this-vps-ip>"
echo "  Only continue once that second login works."
echo "=========================================================================="
read -rp "Press Enter once you've confirmed a second login works... "
echo ""

}


# ==== Step: derper-build (install binary) ==========================================

step_derper_build() {

echo "=== Installing derper ==="
echo ""
apt install -y golang-go git certbot

export GOPATH=/root/go
export PATH=$PATH:/root/go/bin
go install tailscale.com/cmd/derper@latest
cp /root/go/bin/derper /usr/local/bin/derper
mkdir -p /var/lib/derper/certs

}


# ==== Step: derper-cert =============================================================

step_derper_cert() {

# NOTE: guac.$DOMAIN does NOT need its own cert here — cloudflared proxies
# that route as plain HTTP internally (Cloudflare handles public TLS for it).
# Only derper needs a real cert, because Tailscale clients expect derper to
# terminate genuine end-to-end TLS itself, not have it terminated upstream.
echo "=== Obtaining derper's cert via certbot standalone ==="
echo ""
certbot certonly --standalone -d "$DERP_HOST" \
  --preferred-challenges http -m "$EMAIL" --agree-tos --non-interactive

cp "/etc/letsencrypt/live/$DERP_HOST/fullchain.pem" "/var/lib/derper/certs/$DERP_HOST.crt"
cp "/etc/letsencrypt/live/$DERP_HOST/privkey.pem" "/var/lib/derper/certs/$DERP_HOST.key"

}


# ==== Step: derper-service ===========================================================

step_derper_service() {

echo "=== Creating derper systemd service ==="
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

}


# ==== Step: cloudflared-install ========================================================

step_cloudflared_install() {

echo "=== Installing cloudflared ==="
echo ""
curl -L --output /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i /tmp/cloudflared.deb

}


# ==== Step: cloudflared-auth ============================================================

step_cloudflared_auth() {

manual_step "Authorize cloudflared" \
  "Run this command on the VPS now (in another terminal, or after this pauses):" \
  "    cloudflared tunnel login" \
  "It prints a URL. Open that URL in any browser, log into Cloudflare, and" \
  "authorize it for your domain ($DOMAIN). This downloads a cert.pem this" \
  "script needs to continue."

}


# ==== Step: cloudflared-config ===========================================================

step_cloudflared_config() {

echo "=== Creating tunnel, config, and DNS routes ==="
echo ""
if ! cloudflared tunnel list 2>/dev/null | grep -q "$CF_TUNNEL_NAME"; then
  cloudflared tunnel create "$CF_TUNNEL_NAME"
fi
TUNNEL_ID="$(cloudflared tunnel list | awk -v n="$CF_TUNNEL_NAME" '$2==n {print $1}')"
if [ -z "$TUNNEL_ID" ]; then
  echo "ERROR: could not determine tunnel ID for '$CF_TUNNEL_NAME'. Check 'cloudflared tunnel list'." >&2
  exit 1
fi
echo "Tunnel ID: $TUNNEL_ID"

CRED_FILE="/root/.cloudflared/${TUNNEL_ID}.json"
if [ ! -f "$CRED_FILE" ]; then
  ALT_CRED_FILE="$(find / -maxdepth 4 -name "${TUNNEL_ID}.json" 2>/dev/null | head -1)"
  if [ -n "$ALT_CRED_FILE" ] && [ "$ALT_CRED_FILE" != "$CRED_FILE" ]; then
    mkdir -p /root/.cloudflared
    cp "$ALT_CRED_FILE" "$CRED_FILE"
    CERT_SRC="$(dirname "$ALT_CRED_FILE")/cert.pem"
    [ -f "$CERT_SRC" ] && cp "$CERT_SRC" /root/.cloudflared/cert.pem
    echo "NOTE: copied tunnel credentials from $ALT_CRED_FILE to $CRED_FILE"
    echo "      (this happens if 'tunnel login'/'create' ran as a non-root user)"
  fi
fi

mkdir -p /etc/cloudflared
cat > /etc/cloudflared/config.yml << EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $DERP_HOST
    service: https://localhost:$DERPER_PORT
    originRequest:
      noTLSVerify: true
      originServerName: $DERP_HOST
  - hostname: $GUAC_HOST
    service: http://localhost:$GUAC_TUNNEL_PORT
  - service: http_status:404
EOF

cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$DERP_HOST"
cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$GUAC_HOST"

sudo cloudflared service install
systemctl enable --now cloudflared

}


# ==== Step: renewal-hook ==================================================================

step_renewal_hook() {

echo "=== Setting up cert renewal hook ==="
echo ""
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/derper-reload.sh << EOF
#!/bin/bash
cp /etc/letsencrypt/live/$DERP_HOST/fullchain.pem /var/lib/derper/certs/$DERP_HOST.crt
cp /etc/letsencrypt/live/$DERP_HOST/privkey.pem /var/lib/derper/certs/$DERP_HOST.key
systemctl restart derper
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/derper-reload.sh

}


# ==== Step: verify =========================================================================

step_verify() {

echo "=== Verification ==="
echo ""
sleep 3
echo "--- derper status ---"
systemctl is-active derper || true
echo "--- cloudflared status ---"
systemctl is-active cloudflared || true
echo "--- local curl test (via cloudflared, may need a minute to warm up) ---"
curl -sI "https://$DERP_HOST/" || echo "curl failed — try again in a minute, DNS/tunnel may still be propagating"

}


# ==== Step: tailscale-acl ====================================================================

step_tailscale_acl() {

VPS_IP="$(curl -4 -s ifconfig.me || echo '<could-not-detect-run-curl -4 ifconfig.me-manually>')"

manual_step "Add the custom DERP region to your Tailscale ACL" \
  "Go to https://login.tailscale.com/admin/acls and add this to the policy JSON" \
  "(as a sibling of your existing \"acls\" key — don't remove anything else):" \
  "" \
  '  "derpMap": {' \
  '    "OmitDefaultRegions": false,' \
  '    "Regions": {' \
  '      "900": {' \
  '        "RegionID": 900,' \
  '        "RegionCode": "custom",' \
  "        \"RegionName\": \"My VPS\"," \
  '        "Nodes": [' \
  '          {' \
  '            "Name": "900a",' \
  '            "RegionID": 900,' \
  "            \"HostName\": \"$DERP_HOST\"," \
  "            \"IPv4\": \"$VPS_IP\"" \
  '          }' \
  '        ]' \
  '      }' \
  '    }' \
  '  }' \
  "" \
  "The \"IPv4\" field is IMPORTANT: it makes Tailscale's STUN probe hit this" \
  "VPS directly instead of via Cloudflare (Cloudflare Tunnel doesn't proxy" \
  "raw UDP/STUN, so without this the region will always show blank latency" \
  "in 'tailscale netcheck' and never get selected as a relay)."

}


# ==== Run selected steps =====================================================================

should_run cloudflare-account   && step_cloudflare_account
should_run hardening            && step_hardening
should_run ssh-harden           && step_ssh_harden
should_run derper-build          && step_derper_build
should_run derper-cert           && step_derper_cert
should_run derper-service        && step_derper_service
should_run cloudflared-install   && step_cloudflared_install
should_run cloudflared-auth      && step_cloudflared_auth
should_run cloudflared-config    && step_cloudflared_config
should_run renewal-hook          && step_renewal_hook
should_run verify                && step_verify
should_run tailscale-acl         && step_tailscale_acl

echo "=== Done. Steps run: $RUN_STEPS ==="
if [ "$STEPS" = "all" ]; then
  echo "  - derp.$DOMAIN  -> derper (via Cloudflare Tunnel + direct STUN on UDP 3478)"
  echo "  - guac.$DOMAIN  -> whatever the client's SSH tunnel forwards to port $GUAC_TUNNEL_PORT"
  echo "  Next: run client.sh on the machine hosting your local app,"
  echo "  then verify with: tailscale netcheck / tailscale ping <peer-ip>"
fi
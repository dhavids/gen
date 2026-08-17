# derp-guac-vps-setup

Scripts to self-host a [Tailscale DERP relay](https://tailscale.com/kb/1118/custom-derp-servers) and expose a local web app (e.g. [Apache Guacamole](https://guacamole.apache.org/)) over a plain outbound SSH tunnel — both sharing port 443 on a single cheap VPS via [Caddy](https://caddyserver.com/) + the [`layer4`](https://github.com/mholt/caddy-l4) plugin for SNI-based TCP passthrough.

The scripts and notes here reflect what actually worked, including the dead ends.

## Why this exists

- **DERP relay**: if you're behind a network with poor/asymmetric NAT or a congested public DERP node, running your own relay in a nearby region can cut Tailscale relay latency dramatically.
- **Guacamole (or any local web app) over SSH tunnel**: sidesteps relying on a mesh VPN entirely for a specific service, using nothing but an outbound SSH connection — useful when the mesh VPN itself is degraded or blocked on the local network.

## What's in this repo

- `server.sh` — run on a fresh Ubuntu 24.04 VPS. Installs and configures derper, builds Caddy with the `layer4` plugin, gets Let's Encrypt certs via certbot standalone, wires up systemd services and a cert-renewal hook.
- `client.sh` — run on the machine hosting the local service you want to expose (e.g. wherever Guacamole runs). Sets up a persistent `autossh` reverse tunnel to the VPS.
- `SETUP-GUIDE.md` — full walkthrough, including the specific gotchas hit along the way (see below).

## Quick start

**1. Manual prerequisites (can't be scripted):**
- Create a VPS (any provider with a real public IPv4; see note on IP reputation below)
- Point two DNS A records at it: one for the relay, one for the tunneled app
- If using Tailscale's custom DERP feature, add a `derpMap` block to your tailnet's ACL policy (see `SETUP-GUIDE.md`)

**2. On the VPS:**
```bash
sudo DOMAIN=example.com \
     EMAIL=you@example.com \
     TUNNEL_USER=tunnel \
     bash vps-setup.sh
```
(This derives `derp.example.com` and `guac.example.com` automatically. Pass `DERP_HOST`/`GUAC_HOST` directly instead if you want different subdomain names.)

**3. On the client machine:**
```bash
VPS_HOST=203.0.113.10 \
VPS_USER=tunnel \
GUAC_LOCAL_PORT=8080 \
bash client.sh
```

## Gotchas this repo already solves for you

- `derper`'s built-in `--certmode=letsencrypt` **only** attempts automatic ACME issuance when bound directly to port `:443`. Running it on an internal port behind a reverse proxy (needed to share 443 with another service) silently falls back to plain HTTP with no error. Fix: get the cert manually via certbot and use `--certmode=manual`.
- Caddy's `layer4` plugin's own `tls { cert_file ... }` Caddyfile subdirective doesn't parse correctly in current builds. Workaround used here: `layer4` does pure TCP passthrough by SNI, handing off to Caddy's normal, well-documented HTTP app on an internal port for actual TLS termination.
- Caddy's `auto_https` automatically grabs port 80 the moment *any* HTTPS site block exists, even if you never asked for a redirect — this silently breaks certbot's standalone renewal (`Could not bind TCP port 80`). Fix: `auto_https off`.
- `autossh`'s SSH option is `ServerAliveCountMax`, not `ServerAliveCountInterval` (the latter doesn't exist and fails silently at connection time).

## A note on IP reputation

Not all IPs are transversable by all networks. Check which works for you first.

## License

MIT — do whatever you want with this.
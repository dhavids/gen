# derp-guac-vps-setup

Scripts to self-host a [Tailscale DERP relay](https://tailscale.com/kb/1118/custom-derp-servers) and expose a local web app (e.g. [Apache Guacamole](https://guacamole.apache.org/)) publicly — both fronted by **Cloudflare Tunnel**, so the VPS never needs an inbound public port 443 at all.

Built after a restrictive network blocked direct connections to a VPS's raw IP on port 443. Cloudflare Tunnel sidesteps this: the VPS makes only *outbound* connections to Cloudflare's edge, and public traffic hits Cloudflare's shared IP range — the same range used by a huge share of the internet, not something most networks can block wholesale.

The scripts and notes here reflect what actually worked, including the dead ends (an earlier Caddy + `layer4` SNI-passthrough approach is documented below in case it's useful elsewhere, but this repo no longer uses it).

## Architecture

```
Tailscale peers  --(UDP 3478, STUN, direct)-->  VPS
Tailscale peers  --(HTTPS)-->  Cloudflare edge  --(tunnel)-->  VPS:derper
Browser          --(HTTPS)-->  Cloudflare edge  --(tunnel)-->  VPS:9000 --(SSH tunnel)--> client machine's local app
```

- **derper** (the DERP relay) still needs a real, direct TLS cert and still needs **UDP 3478 open publicly on the VPS** — Cloudflare Tunnel doesn't proxy raw UDP, so Tailscale's STUN-based connectivity probing has to reach the VPS directly. Everything else about derper's traffic goes through the tunnel.
- **The local web app** (Guacamole or anything else) needs no cert at all on the VPS side — Cloudflare terminates public TLS, and the tunnel carries plain HTTP internally to a port that an SSH reverse tunnel from the client machine forwards to.

## What's in this repo

Scripts live at `gen/cloud/sh/` in this repo:

- `server.sh` — run on a fresh Ubuntu 24.04 VPS. Handles everything scriptable: hardening, derper install + cert, cloudflared install, tunnel/config/DNS routing, systemd services, cert renewal hook.
- `client.sh` — run on the machine hosting the local service you want to expose. Sets up a persistent `autossh` reverse tunnel to the VPS.

## What can and can't be automated

Both scripts do as much as possible automatically, but a few things fundamentally require a browser, your own accounts, or a one-time human decision — no script can do these safely. **Both scripts pause and print exact instructions at each such point**, waiting for you to press Enter once you've done it.

| Step | Automatable? |
|---|---|
| VPS hardening, user setup, firewall | ✅ Scripted |
| Disabling SSH root login + password auth | ❌ Manual, prompted — risky to fully automate (lockout risk if misconfigured) |
| Installing derper + getting its cert | ✅ Scripted |
| Installing cloudflared | ✅ Scripted |
| Creating a Cloudflare account & adding your domain | ❌ Manual — browser, your account |
| Changing your domain's nameservers to Cloudflare's | ❌ Manual — your registrar's dashboard |
| `cloudflared tunnel login` (authorizing the VPS) | ❌ Manual — opens a URL, needs a browser click |
| Creating the tunnel, writing its config, routing DNS | ✅ Scripted (once login above is done) |
| systemd services + cert renewal hook | ✅ Scripted |
| Adding the custom DERP region to your Tailscale ACL | ❌ Manual — Tailscale's web console |
| Authorizing the client's SSH key on the VPS (first time) | ❌ Manual — needs the VPS account's password once |
| Setting up the client's reverse tunnel | ✅ Scripted (after the key is authorized) |

## Quick start

**1. On the VPS:**
```bash
cd gen/cloud/sh
sudo bash server.sh \
  --domain example.com \
  --email you@example.com \
  --tunnel-user-password 'some-strong-password'
```
This derives `derp.example.com` and `guac.example.com` automatically. It will pause twice — once for the Cloudflare account/domain setup, once for `cloudflared tunnel login` — with exact instructions printed each time. Run `sudo bash server.sh --help` for the full flag list.

**2. On the client machine (wherever your local app runs):**
```bash
cd gen/cloud/sh
bash client.sh \
  --vps-host 203.0.113.10 \
  --vps-user tunnel \
  --guac-local-port 8080
```
It'll pause once if your SSH key isn't authorized on the VPS yet, with the exact command to run. Run `bash client.sh --help` for the full flag list.

**3. Manual — add the DERP region to your Tailscale ACL.** `server.sh` prints the exact JSON to paste, including the VPS's detected public IP — this is required for Tailscale's STUN probing (see architecture note above on why `IPv4` matters here, not just `HostName`).

**4. Verify:**
```bash
# From any client:
tailscale netcheck        # your custom region should show a real latency, not blank
tailscale ping <peer-ip>  # should show via DERP(<your-region>) once selected

# In a browser (not curl — see note below):
https://guac.example.com/guacamole/
```

## Gotchas this repo already solves for you

- **derper's own `--certmode=letsencrypt` only works when bound directly to port `:443`.** Since derper runs on an internal port here, it needs `--certmode=manual` with a cert obtained separately via `certbot certonly --standalone`.
- **Cloudflare Tunnel's `originRequest` needs `originServerName` set explicitly** when the origin (derper) enforces strict SNI/hostname matching on its cert — without it, `cloudflared` may present the literal string `localhost` as SNI (since that's what's in the `service:` URL), which derper rejects as a cert mismatch even with `noTLSVerify: true` set.
- **`curl` may get reset by Cloudflare's bot/TLS-fingerprint protections even when everything is actually working.** If `curl -I https://your-host/` fails but the same URL loads fine in a real browser, that's very likely this — not a real problem with your setup. Test with a browser, not `curl`, when in doubt.
- **Tailscale's DERP latency measurement in `netcheck` is done via STUN over UDP 3478, not the TCP/HTTPS relay path.** If a custom DERP region shows blank latency despite the relay itself working, and it's fronted by Cloudflare Tunnel (which doesn't proxy raw UDP), add an explicit `"IPv4"` field to the region's node in your `derpMap` ACL entry, pointing at the VPS's real IP — this lets STUN reach the VPS directly while the actual relay data still flows through the tunnel.
- `autossh`'s SSH option is `ServerAliveCountMax`, not `ServerAliveCountInterval` (the latter doesn't exist and fails silently at connection time).

## A note on domain age and category-based blocking

If a brand-new domain gets blocked with a message naming a category like **"newly-registered-domain"** (a real, common firewall category on enterprise/managed networks), this isn't something Cloudflare Tunnel, IP rotation, or any of the above fixes solve — it's blocking by *domain name*, evaluated regardless of what's behind it. Options: wait for the domain to age out of that category (commonly ~30 days), use an already-aged domain you own, or ask the network's IT team for an allowlist exception (concrete evidence — the exact block message and category — makes this a much easier request).

## A note on IP reputation

Not all IPs are traversable by all networks, independent of domain-based filtering. Cloud provider IPs get recycled between customers, and a prior tenant's abuse history can get an IP flagged in commercial threat-intel feeds that some networks subscribe to. If direct-IP connectivity ever matters for your setup, check the VPS's IP on [AbuseIPDB](https://www.abuseipdb.com) before assuming a block is something more exotic — a fresh IP sometimes resolves it outright.

## Earlier approach (superseded, kept for reference)

An earlier version of this setup exposed the VPS's IP directly on port 443, using [Caddy](https://caddyserver.com/) + the [`layer4`](https://github.com/mholt/caddy-l4) plugin for SNI-based TCP passthrough so both `derp.*` and `guac.*` could share one port without a wildcard cert or multiple IPs. It worked, but direct IP exposure turned out to be exactly what got blocked on a restrictive network — hence the move to Cloudflare Tunnel above. If you're on a network without that kind of filtering, the Caddy/`layer4` approach is simpler (no Cloudflare account needed) and the same core gotchas around derper's cert mode still apply.

## License

MIT — do whatever you want with this.
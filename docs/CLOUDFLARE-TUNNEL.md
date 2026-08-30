# Cloudflare Tunnel

## Why Tunnel

The Vault backend is intentionally local-only. Cloudflare Tunnel publishes the service without requiring a new inbound VPS port or an origin TLS certificate for this application.

## Install cloudflared

On Debian/Ubuntu:

```bash
curl -fsSLo /tmp/install-cloudflared.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/install-cloudflared.sh
sudo bash /tmp/install-cloudflared.sh
```

## Create a remotely-managed Tunnel

In Cloudflare, create a Tunnel and follow the generated Linux command, which looks like:

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
```

Never publish the token.

## Published application

Configure:

```text
Hostname: notify.example.com
Service:  http://127.0.0.1:29444
```

Do not point this hostname directly to the residential WAN IP.

If the hostname previously had an A/AAAA record, remove the conflicting record before attaching the hostname to the Tunnel.

## HTTPS

The browser-facing HTTPS certificate is managed at Cloudflare Edge. The local hop from `cloudflared` to `127.0.0.1:29444` stays on the VPS loopback interface, so the Vault backend itself does not need a certificate.

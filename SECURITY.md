# Security Policy

## Never publish secrets

Do not commit, paste into issues, or include in screenshots/logs:

- `WRITE_TOKEN`
- Cloudflare Tunnel token
- browser session cookies
- `SESSION_SECRET`
- private keys
- login passwords
- `/etc/wan2-vault/secrets.json`
- `/etc/wan2-vault/auth.json`
- `/etc/wan2-vault.conf`

If a secret is exposed, rotate it rather than continuing to rely on it.

## Intended deployment boundary

The server application binds only to `127.0.0.1:29444` (or `::1` when explicitly configured) and refuses non-loopback bind addresses.

Supported public ingress:

- Cloudflare Tunnel -> localhost backend
- Cloudflare proxy -> local Nginx/reverse proxy -> localhost backend

The OpenWrt component performs outbound HTTPS only. It does not add firewall ACCEPT rules or start an HTTP/HTTPS listener on WAN interfaces.

## Cloudflare trust boundary

Every IP update requires:

1. the correct `WRITE_TOKEN`; and
2. the posted IPv4 to match Cloudflare's `CF-Connecting-IP`.

Multi-WAN sends a separate update through each WAN's own `l3_device`, so one request proves only the address of the egress path that carried it.

The inventory endpoint carries interface names/devices and active state. It also requires the WRITE_TOKEN and a Cloudflare-provided client address, but inventory data never replaces the per-IP source match.

A hostile local process on the VPS can forge HTTP headers. The localhost reverse proxy/cloudflared process and root-controlled proxy configuration are therefore part of the trusted computing base.

Cloudflare can observe traffic metadata and client IP information handled by its proxy infrastructure.

## Password storage

Passwords are stored only as salted scrypt hashes. The installer does not persist the plain password.

## Sessions

Browser sessions use random tokens. The server stores only a SHA-256 hash of each session token. Cookies use `Secure`, `HttpOnly`, and `SameSite=Strict`.

Persistent sessions use sliding renewal. Browser policy or site-data cleanup can still end a session.

## Upgrades

Server upgrades validate downloaded code before activation and keep a pre-upgrade backup. Application configuration, authentication files and WRITE_TOKEN are not replaced by normal upgrades.

OpenWrt upgrades preserve the existing secret configuration and migrate v1.0 single-WAN installs to manual tracking so an upgrade does not unexpectedly report additional WAN interfaces.

## Reporting vulnerabilities

When reporting a security issue, redact real domains, public IP addresses, tokens, cookies, private keys, and passwords.

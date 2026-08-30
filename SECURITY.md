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

The server application is designed to bind only to `127.0.0.1:29444` and be published through Cloudflare Tunnel. It refuses a non-loopback bind address in application code.

The OpenWrt component performs outbound HTTPS only. It does not add firewall ACCEPT rules or start an HTTP/HTTPS listener on the WAN interface.

## Cloudflare trust boundary

The update endpoint requires both:

1. the correct `WRITE_TOKEN`; and
2. the posted IPv4 to match Cloudflare's `CF-Connecting-IP`.

This design assumes the application is reachable only through the local `cloudflared` process. A hostile local process on the VPS can forge HTTP headers, so localhost access remains part of the trusted computing base.

Cloudflare can observe traffic metadata and client IP information handled by its proxy infrastructure.

## Password storage

Passwords are stored only as a salted scrypt hash. The plain password is not written to disk by the installer.

## Sessions

Browser sessions use random tokens. The server stores only a SHA-256 hash of each session token. Cookies use `Secure`, `HttpOnly`, and `SameSite=Strict`.

Persistent sessions use sliding renewal. Browser policy or site-data cleanup can still end a session.

## Reporting vulnerabilities

When reporting a security issue, redact real domains, public IP addresses, tokens, cookies, private keys, and passwords.

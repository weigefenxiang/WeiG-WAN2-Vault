# VPS installation and upgrades

## Install

```bash
curl -fsSLo /tmp/wan2-vault-install.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/install.sh
sudo bash /tmp/wan2-vault-install.sh
```

The application binds only:

```text
127.0.0.1:29444
```

The installer creates login credentials, a dedicated WRITE_TOKEN, and the systemd service.

## Management

```bash
sudo wan2-vault status
sudo wan2-vault version
sudo wan2-vault check-update
sudo wan2-vault upgrade
sudo wan2-vault rollback
sudo wan2-vault manage
```

## Upgrade behavior

`wan2-vault upgrade` downloads the latest application, service, CLI and VERSION, then:

1. validates Python and shell syntax;
2. creates a timestamped backup under `/var/lib/wan2-vault/backups/`;
3. installs the new files;
4. restarts systemd;
5. performs a localhost health check using the configured Host header;
6. automatically restores the backup if activation fails.

Configuration, credentials, session data and WRITE_TOKEN are not replaced.

## v1.0 state migration

The v1.1 server can read the old:

```json
{"ip":"203.0.113.10","updated_at":1234567890}
```

as a `WAN2` record. No manual state-file conversion is required.

## Ingress

Choose one:

- Cloudflare Tunnel -> `http://127.0.0.1:29444`
- Cloudflare proxy -> local Nginx/reverse proxy -> `http://127.0.0.1:29444`

The reverse proxy must preserve Cloudflare's `CF-Connecting-IP` header.

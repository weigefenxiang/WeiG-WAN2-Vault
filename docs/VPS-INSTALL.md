# VPS Installation

## Requirements

- Debian or Ubuntu
- systemd
- Python 3
- curl or wget
- OpenSSL

## Install

```bash
curl -fsSLo /tmp/wan2-vault-install.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/install.sh
sudo bash /tmp/wan2-vault-install.sh
```

The installer creates:

```text
/etc/wan2-vault/config.json
/etc/wan2-vault/auth.json
/etc/wan2-vault/secrets.json
/var/lib/wan2-vault/
/usr/local/lib/wan2-vault/wan2-vault.py
/etc/systemd/system/wan2-vault.service
```

The service runs as the dedicated `wan2vault` system user.

## Verify bind address

```bash
ss -lntp | grep 29444
```

Expected:

```text
127.0.0.1:29444
```

If it shows `0.0.0.0:29444`, stop and fix the deployment before publishing it.

## Service status

```bash
systemctl status wan2-vault --no-pager
journalctl -u wan2-vault --no-pager -n 50
```

The application disables normal HTTP access logging and does not intentionally log passwords, tokens, cookies, or WAN IP history.

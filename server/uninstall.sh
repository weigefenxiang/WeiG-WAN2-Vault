#!/bin/bash
set -euo pipefail

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

systemctl disable --now wan2-vault.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/wan2-vault.service
rm -f /usr/local/sbin/wan2-vault
rm -rf /usr/local/lib/wan2-vault
systemctl daemon-reload

printf 'Delete local configuration, sessions, WAN state, and update backups too? [y/N]: '
read -r PURGE
case "$PURGE" in
    y|Y|yes|YES)
        rm -rf /etc/wan2-vault /var/lib/wan2-vault
        if id wan2vault >/dev/null 2>&1; then
            userdel wan2vault >/dev/null 2>&1 || true
        fi
        echo "Application and local data removed."
        ;;
    *)
        echo "Application removed. Local data preserved in /etc/wan2-vault and /var/lib/wan2-vault."
        ;;
esac

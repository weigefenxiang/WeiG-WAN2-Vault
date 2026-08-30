#!/bin/bash
set -euo pipefail

RAW_BASE="${WAN2VAULT_RAW_BASE:-https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main}"
APP="/usr/local/lib/wan2-vault/wan2-vault.py"
SERVICE="/etc/systemd/system/wan2-vault.service"
CLI="/usr/local/sbin/wan2-vault"
VERSION_FILE="/usr/local/lib/wan2-vault/VERSION"
CONFIG_FILE="/etc/wan2-vault/config.json"
CURRENT_FILE="/var/lib/wan2-vault/current.json"
BACKUP_ROOT="/var/lib/wan2-vault/backups"

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
[ -d /etc/wan2-vault ] || { echo "ERROR: WeiG-WAN2-Vault is not installed" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
SUCCESS=0
BACKUP=""

restore_backup() {
    [ -n "$BACKUP" ] && [ -d "$BACKUP" ] || return 0
    echo "Restoring previous version..." >&2
    [ -f "$BACKUP/wan2-vault.py" ] && install -o root -g root -m 0755 "$BACKUP/wan2-vault.py" "$APP"
    [ -f "$BACKUP/wan2-vault.service" ] && install -o root -g root -m 0644 "$BACKUP/wan2-vault.service" "$SERVICE"
    if [ -f "$BACKUP/wan2-vault-cli" ]; then
        install -o root -g root -m 0755 "$BACKUP/wan2-vault-cli" "$CLI"
    else
        rm -f "$CLI"
    fi
    [ -f "$BACKUP/VERSION" ] && install -o root -g root -m 0644 "$BACKUP/VERSION" "$VERSION_FILE"
    if [ -f "$BACKUP/current.json" ]; then
        install -o wan2vault -g wan2vault -m 0600 "$BACKUP/current.json" "$CURRENT_FILE"
    fi
    systemctl daemon-reload || true
    systemctl restart wan2-vault.service || true
}

cleanup() {
    rc=$?
    if [ "$SUCCESS" -ne 1 ] && [ -n "$BACKUP" ]; then
        restore_backup
    fi
    rm -rf "$TMP_DIR"
    return "$rc"
}
trap cleanup EXIT INT TERM

curl -fsSL "$RAW_BASE/server/wan2-vault.py" -o "$TMP_DIR/wan2-vault.py"
curl -fsSL "$RAW_BASE/server/wan2-vault.service" -o "$TMP_DIR/wan2-vault.service"
curl -fsSL "$RAW_BASE/server/wan2-vault" -o "$TMP_DIR/wan2-vault-cli"
curl -fsSL "$RAW_BASE/VERSION" -o "$TMP_DIR/VERSION"

python3 -m py_compile "$TMP_DIR/wan2-vault.py"
bash -n "$TMP_DIR/wan2-vault-cli"

REMOTE_VERSION="$(sed -n '1p' "$TMP_DIR/VERSION")"
LOCAL_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo 1.0.0)"
if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "WeiG-WAN2-Vault is already up to date ($LOCAL_VERSION)."
    SUCCESS=1
    exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_ROOT/$timestamp"
install -d -o root -g root -m 0700 "$BACKUP"
[ -f "$APP" ] && cp -a "$APP" "$BACKUP/wan2-vault.py"
[ -f "$SERVICE" ] && cp -a "$SERVICE" "$BACKUP/wan2-vault.service"
[ -f "$CLI" ] && cp -a "$CLI" "$BACKUP/wan2-vault-cli"
printf '%s\n' "$LOCAL_VERSION" > "$BACKUP/VERSION"
chmod 0600 "$BACKUP/VERSION"
[ -f "$CURRENT_FILE" ] && cp -a "$CURRENT_FILE" "$BACKUP/current.json"

install -o root -g root -m 0755 "$TMP_DIR/wan2-vault.py" "$APP"
install -o root -g root -m 0644 "$TMP_DIR/wan2-vault.service" "$SERVICE"
install -o root -g root -m 0755 "$TMP_DIR/wan2-vault-cli" "$CLI"
install -o root -g root -m 0644 "$TMP_DIR/VERSION" "$VERSION_FILE"

systemctl daemon-reload
systemctl restart wan2-vault.service

HOSTNAME="$(python3 - "$CONFIG_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["public_hostname"])
PY
)"

# Type=simple can report active before the Python process has bound its socket.
# Wait for the actual HTTP endpoint instead of treating that startup race as a failed upgrade.
HEALTHY=0
HTTP_CODE="000"
for attempt in $(seq 1 15); do
    if systemctl is-active --quiet wan2-vault.service; then
        HTTP_CODE="$(curl -sS --connect-timeout 1 -o /dev/null -w '%{http_code}' \
            -H "Host: $HOSTNAME" http://127.0.0.1:29444/ 2>/dev/null || true)"
        if [ "$HTTP_CODE" = "200" ]; then
            HEALTHY=1
            break
        fi
    fi
    sleep 1
done

if [ "$HEALTHY" -ne 1 ]; then
    echo "ERROR: upgraded service did not become healthy (last HTTP ${HTTP_CODE:-000})" >&2
    systemctl status wan2-vault.service --no-pager -l >&2 || true
    journalctl -u wan2-vault.service -n 50 --no-pager >&2 || true
    exit 1
fi

SUCCESS=1
trap - EXIT INT TERM
rm -rf "$TMP_DIR"
echo "WeiG-WAN2-Vault upgraded: $LOCAL_VERSION -> $REMOTE_VERSION"
echo "Backup: $BACKUP"

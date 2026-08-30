#!/bin/bash
set -euo pipefail

RAW_BASE="${WAN2VAULT_RAW_BASE:-https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main}"
APP="/usr/local/lib/wan2-vault/wan2-vault.py"
SERVICE="/etc/systemd/system/wan2-vault.service"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
[ -d /etc/wan2-vault ] || { echo "ERROR: WeiG-WAN2-Vault is not installed" >&2; exit 1; }

curl -fsSL "$RAW_BASE/server/wan2-vault.py" -o "$TMP_DIR/wan2-vault.py"
curl -fsSL "$RAW_BASE/server/wan2-vault.service" -o "$TMP_DIR/wan2-vault.service"
python3 -m py_compile "$TMP_DIR/wan2-vault.py"

cp -a "$APP" "$APP.before-update" 2>/dev/null || true
cp -a "$SERVICE" "$SERVICE.before-update" 2>/dev/null || true

install -o root -g root -m 0755 "$TMP_DIR/wan2-vault.py" "$APP"
install -o root -g root -m 0644 "$TMP_DIR/wan2-vault.service" "$SERVICE"
systemctl daemon-reload
if ! systemctl restart wan2-vault.service; then
    [ -f "$APP.before-update" ] && cp -a "$APP.before-update" "$APP"
    [ -f "$SERVICE.before-update" ] && cp -a "$SERVICE.before-update" "$SERVICE"
    systemctl daemon-reload
    systemctl restart wan2-vault.service || true
    echo "ERROR: update failed; previous files restored" >&2
    exit 1
fi
rm -f "$APP.before-update" "$SERVICE.before-update"
echo "WeiG-WAN2-Vault updated successfully."

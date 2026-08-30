#!/bin/sh
set -eu

CONFIG_FILE="/etc/wan2-vault.conf"
STATE_DIR="/etc/wan2-vault-state"
REPORTER="/usr/bin/wan2-vault-report"
CLI="/usr/bin/wan2-vault"
VERSION_DIR="/usr/share/wan2-vault"
OLD_REPORTER="/etc/wan2-ipnotify.sh"
HOTPLUG="/etc/hotplug.d/iface/95-wan2-ipnotify"
CRON_FILE="/etc/crontabs/root"
CRON_MARK="# WeiG-WAN2-Vault"

[ "$(id -u)" = "0" ] || { echo "ERROR: run as root" >&2; exit 1; }

if [ -f "$CRON_FILE" ]; then
    tmp="/tmp/wan2-vault-cron.$$"
    grep -vF "$CRON_MARK" "$CRON_FILE" | grep -vF "$OLD_REPORTER" > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$CRON_FILE"
    rm -f "$tmp"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
fi

rm -f "$REPORTER" "$CLI" "$OLD_REPORTER" "$HOTPLUG"
rm -rf "$VERSION_DIR" "$STATE_DIR"
rm -f "$CONFIG_FILE"

echo "WeiG-WAN2-Vault removed from OpenWrt."

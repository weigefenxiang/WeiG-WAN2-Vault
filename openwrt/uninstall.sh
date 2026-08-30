#!/bin/sh
set -eu

CONFIG_FILE="/etc/wan2-vault.conf"
REPORTER="/etc/wan2-ipnotify.sh"
HOTPLUG="/etc/hotplug.d/iface/95-wan2-ipnotify"
CRON_FILE="/etc/crontabs/root"
CRON_MARK="# WeiG-WAN2-Vault"
SYSUPGRADE="/etc/sysupgrade.conf"

[ "$(id -u)" = "0" ] || { echo "ERROR: run as root" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT INT TERM

if [ -f "$CRON_FILE" ]; then
    grep -vF "$CRON_MARK" "$CRON_FILE" > "$TMP" 2>/dev/null || true
    cat "$TMP" > "$CRON_FILE"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
fi

rm -f "$CONFIG_FILE" "$REPORTER" "$HOTPLUG" /tmp/wan2-vault.last
rmdir /tmp/wan2-vault.lock 2>/dev/null || true

if [ -f "$SYSUPGRADE" ]; then
    for f in "$CONFIG_FILE" "$REPORTER" "$HOTPLUG" "$CRON_FILE"; do
        grep -vxF "$f" "$SYSUPGRADE" > "$TMP" 2>/dev/null || true
        cat "$TMP" > "$SYSUPGRADE"
    done
fi

echo "WeiG-WAN2-Vault OpenWrt components removed."

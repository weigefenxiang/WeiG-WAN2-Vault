#!/bin/sh
set -eu

RAW_BASE="${WAN2VAULT_RAW_BASE:-https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main}"
CONFIG_FILE="/etc/wan2-vault.conf"
REPORTER="/usr/bin/wan2-vault-report"
OLD_REPORTER="/etc/wan2-ipnotify.sh"
CLI="/usr/bin/wan2-vault"
VERSION_FILE="/usr/share/wan2-vault/VERSION"
STATE_DIR="/etc/wan2-vault-state"
CRON_FILE="/etc/crontabs/root"
CRON_MARK="# WeiG-WAN2-Vault"
SYSUPGRADE="/etc/sysupgrade.conf"
CACHE_BUST="${WAN2VAULT_CACHE_BUST:-$(date +%s)}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || fail "Run as root."
[ -r "$CONFIG_FILE" ] || fail "WeiG-WAN2-Vault is not installed."
command -v curl >/dev/null 2>&1 || fail "curl is required."

fetch_raw() {
    rel="$1"
    out="$2"
    sep='?'
    case "$RAW_BASE" in *\?*) sep='&' ;; esac
    curl -fsSL -H 'Cache-Control: no-cache' "${RAW_BASE}/${rel}${sep}_=${CACHE_BUST}" -o "$out"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

fetch_raw "openwrt/wan2-ipnotify.sh" "$TMP_DIR/reporter"
fetch_raw "openwrt/wan2-vault" "$TMP_DIR/cli"
fetch_raw "VERSION" "$TMP_DIR/VERSION"
sh -n "$TMP_DIR/reporter"
sh -n "$TMP_DIR/cli"

REMOTE_VERSION="$(sed -n '1p' "$TMP_DIR/VERSION")"
LOCAL_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo 1.0.0)"
if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "WeiG-WAN2-Vault is already up to date ($LOCAL_VERSION)."
    exit 0
fi

BACKUP="$TMP_DIR/backup"
mkdir -p "$BACKUP"
cp -a "$CONFIG_FILE" "$BACKUP/config"
[ -f "$REPORTER" ] && cp -a "$REPORTER" "$BACKUP/reporter" || true
[ -f "$OLD_REPORTER" ] && cp -a "$OLD_REPORTER" "$BACKUP/old-reporter" || true
[ -f "$CLI" ] && cp -a "$CLI" "$BACKUP/cli" || true
[ -f "$VERSION_FILE" ] && cp -a "$VERSION_FILE" "$BACKUP/VERSION" || true
[ -f "$CRON_FILE" ] && cp -a "$CRON_FILE" "$BACKUP/cron" || true

rollback() {
    echo "Update failed; restoring previous OpenWrt files." >&2
    cp -a "$BACKUP/config" "$CONFIG_FILE"
    [ -f "$BACKUP/reporter" ] && cp -a "$BACKUP/reporter" "$REPORTER" || rm -f "$REPORTER"
    [ -f "$BACKUP/old-reporter" ] && cp -a "$BACKUP/old-reporter" "$OLD_REPORTER" || true
    [ -f "$BACKUP/cli" ] && cp -a "$BACKUP/cli" "$CLI" || rm -f "$CLI"
    if [ -f "$BACKUP/VERSION" ]; then
        mkdir -p "$(dirname "$VERSION_FILE")"
        cp -a "$BACKUP/VERSION" "$VERSION_FILE"
    else
        rm -f "$VERSION_FILE"
    fi
    [ -f "$BACKUP/cron" ] && cp -a "$BACKUP/cron" "$CRON_FILE" || true
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

SUCCESS=0
cleanup() {
    rc=$?
    if [ "$SUCCESS" -ne 1 ]; then
        rollback
    fi
    rm -rf "$TMP_DIR"
    return "$rc"
}
trap cleanup EXIT INT TERM

# Preserve v1 configuration. If MODE is absent, keep the old single-interface choice.
# shellcheck disable=SC1090
. "$CONFIG_FILE"
if [ -z "${MODE:-}" ]; then
    OLD_IF="${WAN_INTERFACE:-WAN2}"
    tmp_conf="$TMP_DIR/config.new"
    umask 077
    cat > "$tmp_conf" <<EOF
HOSTNAME='$HOSTNAME'
MODE='manual'
INTERFACES='$OLD_IF'
WRITE_TOKEN='$WRITE_TOKEN'
EOF
    install -m 600 "$tmp_conf" "$CONFIG_FILE"
fi

install -m 700 "$TMP_DIR/reporter" "$REPORTER"
install -m 700 "$TMP_DIR/cli" "$CLI"
mkdir -p "$(dirname "$VERSION_FILE")" "$STATE_DIR/interfaces"
install -m 644 "$TMP_DIR/VERSION" "$VERSION_FILE"
chmod 700 "$STATE_DIR" "$STATE_DIR/interfaces"

mkdir -p /etc/crontabs
touch "$CRON_FILE"
grep -vF "$CRON_MARK" "$CRON_FILE" > "$TMP_DIR/cron.1" 2>/dev/null || true
grep -vF "$OLD_REPORTER" "$TMP_DIR/cron.1" > "$TMP_DIR/cron.2" 2>/dev/null || true
{
    cat "$TMP_DIR/cron.2"
    echo "*/5 * * * * $REPORTER >/dev/null 2>&1 $CRON_MARK"
} > "$CRON_FILE"
chmod 600 "$CRON_FILE"
/etc/init.d/cron restart >/dev/null 2>&1 || true

rm -f /etc/hotplug.d/iface/95-wan2-ipnotify
rm -f "$OLD_REPORTER"

touch "$SYSUPGRADE"
for f in "$CONFIG_FILE" "$STATE_DIR" "$REPORTER" "$CLI" "$VERSION_FILE" "$CRON_FILE"; do
    grep -qxF "$f" "$SYSUPGRADE" 2>/dev/null || echo "$f" >> "$SYSUPGRADE"
done

# A report failure is a network/runtime issue, not an updater failure.
"$REPORTER" >/dev/null 2>&1 || true

SUCCESS=1
trap - EXIT INT TERM
rm -rf "$TMP_DIR"
echo "WeiG-WAN2-Vault upgraded: $LOCAL_VERSION -> $REMOTE_VERSION"
if grep -q "^MODE='manual'" "$CONFIG_FILE" 2>/dev/null; then
    echo "Existing single-WAN selection was preserved."
    echo "To track every WAN: wan2-vault interfaces auto"
fi

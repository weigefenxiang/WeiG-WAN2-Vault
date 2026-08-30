#!/bin/sh
set -eu

RAW_BASE="${WAN2VAULT_RAW_BASE:-https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main}"
CONFIG_FILE="/etc/wan2-vault.conf"
LEGACY_TOKEN_FILE="/etc/wan2-vault.token"
LEGACY_LAST_IP_FILE="/etc/wan2-vault.last-ip"
REPORTER="/usr/bin/wan2-vault-report"
OLD_REPORTER="/etc/wan2-ipnotify.sh"
CLI="/usr/bin/wan2-vault"
VERSION_FILE="/usr/share/wan2-vault/VERSION"
STATE_DIR="/etc/wan2-vault-state"
CRON_FILE="/etc/crontabs/root"
CRON_MARK="# WeiG-WAN2-Vault"
SYSUPGRADE="/etc/sysupgrade.conf"
CACHE_BUST="${WAN2VAULT_CACHE_BUST:-$(date +%s)}"
LEGACY_MANUAL=0

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" = "0" ] || fail "Run as root."
command -v curl >/dev/null 2>&1 || fail "curl is required."

if [ ! -r "$CONFIG_FILE" ]; then
    if [ -r "$LEGACY_TOKEN_FILE" ] && [ -r "$REPORTER" ]; then
        LEGACY_MANUAL=1
        info "Detected legacy manual installation; configuration will be migrated automatically."
    else
        fail "WeiG-WAN2-Vault is not installed."
    fi
fi

fetch_raw() {
    rel="$1"
    out="$2"
    sep='?'
    case "$RAW_BASE" in *\?*) sep='&' ;; esac
    curl -fsSL -H 'Cache-Control: no-cache' "${RAW_BASE}/${rel}${sep}_=${CACHE_BUST}" -o "$out"
}

strip_quotes() {
    value="$1"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

valid_hostname() {
    case "$1" in
        ''|*[!A-Za-z0-9.-]*|.*|*..*|*.) return 1 ;;
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_interface() {
    case "$1" in ''|*[!A-Za-z0-9_.:@-]*) return 1 ;; *) return 0 ;; esac
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
if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ] && [ "${FORCE:-0}" != "1" ] && [ "$LEGACY_MANUAL" -ne 1 ]; then
    echo "WeiG-WAN2-Vault is already up to date ($LOCAL_VERSION)."
    exit 0
fi

BACKUP="$TMP_DIR/backup"
mkdir -p "$BACKUP"
[ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "$BACKUP/config" || true
[ -f "$LEGACY_TOKEN_FILE" ] && cp -a "$LEGACY_TOKEN_FILE" "$BACKUP/legacy-token" || true
[ -f "$LEGACY_LAST_IP_FILE" ] && cp -a "$LEGACY_LAST_IP_FILE" "$BACKUP/legacy-last-ip" || true
[ -f "$REPORTER" ] && cp -a "$REPORTER" "$BACKUP/reporter" || true
[ -f "$OLD_REPORTER" ] && cp -a "$OLD_REPORTER" "$BACKUP/old-reporter" || true
[ -f "$CLI" ] && cp -a "$CLI" "$BACKUP/cli" || true
[ -f "$VERSION_FILE" ] && cp -a "$VERSION_FILE" "$BACKUP/VERSION" || true
[ -f "$CRON_FILE" ] && cp -a "$CRON_FILE" "$BACKUP/cron" || true
[ -f "$SYSUPGRADE" ] && cp -a "$SYSUPGRADE" "$BACKUP/sysupgrade" || true

rollback() {
    echo "Update failed; restoring previous OpenWrt files." >&2
    if [ -f "$BACKUP/config" ]; then cp -a "$BACKUP/config" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
    if [ -f "$BACKUP/legacy-token" ]; then cp -a "$BACKUP/legacy-token" "$LEGACY_TOKEN_FILE"; else rm -f "$LEGACY_TOKEN_FILE"; fi
    if [ -f "$BACKUP/legacy-last-ip" ]; then cp -a "$BACKUP/legacy-last-ip" "$LEGACY_LAST_IP_FILE"; else rm -f "$LEGACY_LAST_IP_FILE"; fi
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
    [ -f "$BACKUP/sysupgrade" ] && cp -a "$BACKUP/sysupgrade" "$SYSUPGRADE" || true
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

if [ "$LEGACY_MANUAL" -eq 1 ]; then
    LEGACY_URL="$(sed -n 's/^[[:space:]]*URL=//p' "$REPORTER" | sed -n '1p')"
    LEGACY_URL="$(strip_quotes "$LEGACY_URL")"
    HOSTNAME="${LEGACY_URL#https://}"
    HOSTNAME="${HOSTNAME#http://}"
    HOSTNAME="${HOSTNAME%%/*}"
    valid_hostname "$HOSTNAME" || fail "Could not determine a valid hostname from the legacy reporter."

    OLD_IF="$(sed -n -e 's/^[[:space:]]*INTERFACE=//p' -e 's/^[[:space:]]*WAN_INTERFACE=//p' "$REPORTER" | sed -n '1p')"
    OLD_IF="$(strip_quotes "$OLD_IF")"
    [ -n "$OLD_IF" ] || OLD_IF="WAN2"
    valid_interface "$OLD_IF" || fail "Could not determine a valid WAN interface from the legacy reporter."

    WRITE_TOKEN="$(sed -n '1p' "$LEGACY_TOKEN_FILE" | tr -d '\r\n')"
    [ "${#WRITE_TOKEN}" -ge 32 ] || fail "Legacy WRITE_TOKEN is invalid or too short."
    case "$WRITE_TOKEN" in *[!A-Za-z0-9_-]*) fail "Legacy WRITE_TOKEN contains unsupported characters." ;; esac

    umask 077
    cat > "$CONFIG_FILE" <<EOF
HOSTNAME='$HOSTNAME'
MODE='manual'
INTERFACES='$OLD_IF'
WRITE_TOKEN='$WRITE_TOKEN'
EOF
    chmod 600 "$CONFIG_FILE"
    unset WRITE_TOKEN
    info "Migrated legacy configuration for interface $OLD_IF."
else
    # Preserve repository v1 configuration. If MODE is absent, keep its old single-interface choice.
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
grep -vF "$REPORTER" "$TMP_DIR/cron.2" > "$TMP_DIR/cron.3" 2>/dev/null || true
{
    cat "$TMP_DIR/cron.3"
    echo "*/5 * * * * $REPORTER >/dev/null 2>&1 $CRON_MARK"
} > "$CRON_FILE"
chmod 600 "$CRON_FILE"
/etc/init.d/cron restart >/dev/null 2>&1 || true

# Remove obsolete legacy triggers so cron is the only scheduler.
if [ -x /etc/init.d/wan2-vault-report ]; then
    /etc/init.d/wan2-vault-report disable >/dev/null 2>&1 || true
fi
rm -f /etc/init.d/wan2-vault-report
rm -f /etc/hotplug.d/iface/95-wan2-vault
rm -f /etc/hotplug.d/iface/95-wan2-ipnotify
rm -f "$OLD_REPORTER"

touch "$SYSUPGRADE"
# Drop obsolete legacy entries before adding the new persistent layout.
for obsolete in "$LEGACY_TOKEN_FILE" "$LEGACY_LAST_IP_FILE" "$OLD_REPORTER" /etc/hotplug.d/iface/95-wan2-vault /etc/hotplug.d/iface/95-wan2-ipnotify /etc/init.d/wan2-vault-report; do
    grep -vFx "$obsolete" "$SYSUPGRADE" > "$TMP_DIR/sysupgrade.clean" 2>/dev/null || true
    cat "$TMP_DIR/sysupgrade.clean" > "$SYSUPGRADE"
done
for f in "$CONFIG_FILE" "$STATE_DIR" "$REPORTER" "$CLI" "$VERSION_FILE" "$CRON_FILE"; do
    grep -qxF "$f" "$SYSUPGRADE" 2>/dev/null || echo "$f" >> "$SYSUPGRADE"
done

# Legacy secret/state files are now superseded by the migrated config/state layout.
rm -f "$LEGACY_TOKEN_FILE" "$LEGACY_LAST_IP_FILE"

# A report failure is a network/runtime issue, not an updater failure.
"$REPORTER" >/dev/null 2>&1 || true

SUCCESS=1
trap - EXIT INT TERM
rm -rf "$TMP_DIR"
echo "WeiG-WAN2-Vault upgraded: $LOCAL_VERSION -> $REMOTE_VERSION"
echo "Existing single-WAN selection was preserved."
echo "To track every WAN: wan2-vault interfaces auto"

#!/bin/sh

CONFIG_FILE="/etc/wan2-vault.conf"
STATE_FILE="/tmp/wan2-vault.last"
LOCK_DIR="/tmp/wan2-vault.lock"
TAG="wan2-vault"

[ -r "$CONFIG_FILE" ] || exit 1
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${HOSTNAME:?HOSTNAME is required}"
: "${WAN_INTERFACE:?WAN_INTERFACE is required}"
: "${WRITE_TOKEN:?WRITE_TOKEN is required}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-1800}"

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

STATUS="$(ubus call "network.interface.${WAN_INTERFACE}" status 2>/dev/null)" || {
    logger -t "$TAG" "Interface status unavailable"
    exit 1
}

UP="$(printf '%s' "$STATUS" | jsonfilter -e '@.up' 2>/dev/null)"
[ "$UP" = "true" ] || exit 0

WAN_IP="$(printf '%s' "$STATUS" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
WAN_DEV="$(printf '%s' "$STATUS" | jsonfilter -e '@.l3_device' 2>/dev/null)"

[ -n "$WAN_IP" ] && [ -n "$WAN_DEV" ] || {
    logger -t "$TAG" "WAN IPv4 or l3_device unavailable"
    exit 1
}

NOW="$(date +%s)"
LAST_IP=""
LAST_OK="0"
if [ -r "$STATE_FILE" ]; then
    LAST_IP="$(sed -n '1p' "$STATE_FILE" 2>/dev/null)"
    LAST_OK="$(sed -n '2p' "$STATE_FILE" 2>/dev/null)"
fi
case "$LAST_OK" in ''|*[!0-9]*) LAST_OK=0 ;; esac
case "$REFRESH_INTERVAL" in ''|*[!0-9]*) REFRESH_INTERVAL=1800 ;; esac

NEED_REPORT=0
[ "$WAN_IP" != "$LAST_IP" ] && NEED_REPORT=1
[ $((NOW - LAST_OK)) -ge "$REFRESH_INTERVAL" ] && NEED_REPORT=1
[ "${FORCE:-0}" = "1" ] && NEED_REPORT=1

[ "$NEED_REPORT" -eq 1 ] || exit 0

URL="https://${HOSTNAME}/api/v1/update"
PAYLOAD="{\"ip\":\"${WAN_IP}\"}"

HTTP_CODE="$(
    curl -4 \
        --interface "$WAN_DEV" \
        -sS \
        --connect-timeout 8 \
        --max-time 20 \
        --retry 2 \
        --retry-delay 2 \
        -o /dev/null \
        -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer ${WRITE_TOKEN}" \
        -H 'Content-Type: application/json' \
        --data-binary "$PAYLOAD" \
        "$URL" 2>/dev/null
)"
RC=$?

if [ "$RC" -eq 0 ] && [ "$HTTP_CODE" = "204" ]; then
    {
        printf '%s\n' "$WAN_IP"
        printf '%s\n' "$NOW"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null
    logger -t "$TAG" "WAN IPv4 reported successfully"
    exit 0
fi

logger -t "$TAG" "WAN IPv4 report failed (HTTP ${HTTP_CODE:-000})"
exit 1

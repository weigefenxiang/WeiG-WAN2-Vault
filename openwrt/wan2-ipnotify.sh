#!/bin/sh

CONFIG_FILE="/etc/wan2-vault.conf"
STATE_DIR="/etc/wan2-vault-state"
LOCK_DIR="/tmp/wan2-vault.lock"
TAG="wan2-vault"
ERRORS=0

[ -r "$CONFIG_FILE" ] || exit 1
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${HOSTNAME:?HOSTNAME is required}"
: "${WRITE_TOKEN:?WRITE_TOKEN is required}"
MODE="${MODE:-manual}"
INTERFACES="${INTERFACES:-${WAN_INTERFACE:-WAN2}}"

case "$MODE" in auto|manual) ;; *) logger -t "$TAG" "Invalid MODE: $MODE"; exit 1 ;; esac

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null; rm -f "$CURRENT_FILE" "$FINGERPRINT_FILE" "$BODY_FILE"' EXIT INT TERM

mkdir -p "$STATE_DIR/interfaces"
chmod 700 "$STATE_DIR" "$STATE_DIR/interfaces" 2>/dev/null || true

CURRENT_FILE="/tmp/wan2-vault.current.$$"
FINGERPRINT_FILE="/tmp/wan2-vault.inventory.$$"
BODY_FILE="/tmp/wan2-vault.response.$$"
: > "$CURRENT_FILE"

valid_name() {
    case "$1" in ''|*[!A-Za-z0-9_.:@-]*) return 1 ;; *) return 0 ;; esac
}

valid_device() {
    case "$1" in *[!A-Za-z0-9_.:@+-]*) return 1 ;; *) return 0 ;; esac
}

read_interface() {
    name="$1"
    valid_name "$name" || return 0
    status="$(ubus call "network.interface.${name}" status 2>/dev/null)" || return 0
    up="$(printf '%s' "$status" | jsonfilter -e '@.up' 2>/dev/null)"
    [ "$up" = "true" ] || return 0
    ip="$(printf '%s' "$status" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
    dev="$(printf '%s' "$status" | jsonfilter -e '@.l3_device' 2>/dev/null)"
    [ -n "$ip" ] && [ -n "$dev" ] || return 0
    valid_device "$dev" || return 0
    targets="$(printf '%s' "$status" | jsonfilter -e '@.route[*].target' 2>/dev/null)"
    printf '%s\n' "$targets" | grep -qx '0.0.0.0' || return 0
    printf '%s|%s|%s\n' "$name" "$ip" "$dev" >> "$CURRENT_FILE"
}

if [ "$MODE" = "auto" ]; then
    for obj in $(ubus list 'network.interface.*' 2>/dev/null); do
        name="${obj#network.interface.}"
        [ "$name" = "$obj" ] && continue
        [ "$name" = "loopback" ] && continue
        read_interface "$name"
    done
else
    for name in $INTERFACES; do
        read_interface "$name"
    done
fi

sort -u "$CURRENT_FILE" -o "$CURRENT_FILE"

if [ "${LIST_ONLY:-0}" = "1" ]; then
    cat "$CURRENT_FILE"
    exit 0
fi

state_for() {
    name="$1"
    file="$STATE_DIR/interfaces/$name"
    OLD_IP=""
    OLD_DEV=""
    if [ -r "$file" ]; then
        OLD_IP="$(sed -n '1p' "$file" 2>/dev/null)"
        OLD_DEV="$(sed -n '2p' "$file" 2>/dev/null)"
    fi
}

save_state() {
    name="$1"; ip="$2"; dev="$3"
    tmp="$STATE_DIR/interfaces/.${name}.$$"
    {
        printf '%s\n' "$ip"
        printf '%s\n' "$dev"
    } > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$STATE_DIR/interfaces/$name"
}

post_update() {
    name="$1"; ip="$2"; dev="$3"
    payload="{\"interface\":\"${name}\",\"device\":\"${dev}\",\"ip\":\"${ip}\"}"
    HTTP_CODE="$(
        curl -4 --interface "$dev" -sS \
            --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 \
            -o "$BODY_FILE" -w '%{http_code}' \
            -X POST "https://${HOSTNAME}/api/v1/update" \
            -H "Authorization: Bearer ${WRITE_TOKEN}" \
            -H 'Content-Type: application/json' \
            --data-binary "$payload" 2>/dev/null
    )"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$HTTP_CODE" = "204" ]; then
        save_state "$name" "$ip" "$dev"
        logger -t "$TAG" "$name IPv4 updated successfully"
        return 0
    fi
    response="$(cat "$BODY_FILE" 2>/dev/null)"
    logger -t "$TAG" "$name report failed (HTTP ${HTTP_CODE:-000})${response:+: $response}"
    return 1
}

# Report each interface only when its IPv4/device changed, unless explicitly forced.
while IFS='|' read -r name ip dev; do
    [ -n "$name" ] || continue
    state_for "$name"
    if [ "${FORCE:-0}" = "1" ] || [ "$ip" != "$OLD_IP" ] || [ "$dev" != "$OLD_DEV" ]; then
        post_update "$name" "$ip" "$dev" || ERRORS=1
    fi
done < "$CURRENT_FILE"

# Inventory changes are separate from IP changes, so removed interfaces become inactive.
: > "$FINGERPRINT_FILE"
while IFS='|' read -r name ip dev; do
    [ -n "$name" ] || continue
    printf '%s|%s\n' "$name" "$dev" >> "$FINGERPRINT_FILE"
done < "$CURRENT_FILE"

NEW_FINGERPRINT="$(cat "$FINGERPRINT_FILE" 2>/dev/null)"
OLD_FINGERPRINT="$(cat "$STATE_DIR/inventory" 2>/dev/null)"
if [ "$NEW_FINGERPRINT" != "$OLD_FINGERPRINT" ] || [ "${FORCE_INVENTORY:-0}" = "1" ]; then
    first_dev="$(sed -n '1s/^[^|]*|[^|]*|\(.*\)$/\1/p' "$CURRENT_FILE")"
    if [ -n "$first_dev" ]; then
        payload='{"interfaces":['
        sep=''
        while IFS='|' read -r name ip dev; do
            [ -n "$name" ] || continue
            payload="${payload}${sep}{\"name\":\"${name}\",\"device\":\"${dev}\"}"
            sep=','
        done < "$CURRENT_FILE"
        payload="${payload}]}"

        HTTP_CODE="$(
            curl -4 --interface "$first_dev" -sS \
                --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 \
                -o "$BODY_FILE" -w '%{http_code}' \
                -X POST "https://${HOSTNAME}/api/v1/inventory" \
                -H "Authorization: Bearer ${WRITE_TOKEN}" \
                -H 'Content-Type: application/json' \
                --data-binary "$payload" 2>/dev/null
        )"
        rc=$?
        if [ "$rc" -eq 0 ] && [ "$HTTP_CODE" = "204" ]; then
            tmp="$STATE_DIR/.inventory.$$"
            cat "$FINGERPRINT_FILE" > "$tmp"
            chmod 600 "$tmp"
            mv "$tmp" "$STATE_DIR/inventory"

            for file in "$STATE_DIR"/interfaces/*; do
                [ -f "$file" ] || continue
                old_name="${file##*/}"
                found=0
                while IFS='|' read -r cur_name cur_ip cur_dev; do
                    if [ "$cur_name" = "$old_name" ]; then
                        found=1
                        break
                    fi
                done < "$CURRENT_FILE"
                [ "$found" -eq 1 ] || rm -f "$file"
            done
            logger -t "$TAG" "WAN interface inventory updated"
        else
            response="$(cat "$BODY_FILE" 2>/dev/null)"
            logger -t "$TAG" "Inventory update failed (HTTP ${HTTP_CODE:-000})${response:+: $response}"
            ERRORS=1
        fi
    fi
fi

exit "$ERRORS"

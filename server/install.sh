#!/bin/bash
set -euo pipefail

PROJECT="WeiG-WAN2-Vault"
RAW_BASE="${WAN2VAULT_RAW_BASE:-https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main}"
ETC_DIR="/etc/wan2-vault"
STATE_DIR="/var/lib/wan2-vault"
LIB_DIR="/usr/local/lib/wan2-vault"
SERVICE_FILE="/etc/systemd/system/wan2-vault.service"
SERVICE_NAME="wan2-vault.service"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

[ "${EUID:-$(id -u)}" -eq 0 ] || fail "Run this installer as root."
command -v systemctl >/dev/null 2>&1 || fail "systemd is required."

install_pkg_if_missing() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    if command -v apt-get >/dev/null 2>&1; then
        info "Installing missing dependency: $pkg"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
    else
        fail "Missing '$cmd'. Install package '$pkg' first."
    fi
}

install_pkg_if_missing python3 python3
install_pkg_if_missing openssl openssl
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    install_pkg_if_missing curl curl
fi

printf '\nWeiG WAN2 Vault installer\n\n'

while :; do
    read -r -p "Public hostname (example: notify.example.com): " PUBLIC_HOSTNAME
    PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME#http://}"
    PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME#https://}"
    PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME%%/*}"
    if [[ "$PUBLIC_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$PUBLIC_HOSTNAME" == *.* ]]; then
        PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME,,}"
        break
    fi
    echo "Invalid hostname. Enter a hostname only, without https:// or a path."
done

while :; do
    read -r -p "Login username: " LOGIN_USERNAME
    [ -n "$LOGIN_USERNAME" ] && [ "${#LOGIN_USERNAME}" -le 128 ] && break
    echo "Username must be 1-128 characters."
done

while :; do
    printf 'Login password (minimum 12 characters): '
    stty -echo
    IFS= read -r LOGIN_PASSWORD
    stty echo
    printf '\n'
    [ "${#LOGIN_PASSWORD}" -ge 12 ] || { echo "Password is too short."; continue; }
    printf 'Confirm password: '
    stty -echo
    IFS= read -r LOGIN_PASSWORD_2
    stty echo
    printf '\n'
    [ "$LOGIN_PASSWORD" = "$LOGIN_PASSWORD_2" ] || { echo "Passwords do not match."; continue; }
    unset LOGIN_PASSWORD_2
    break
done

if id wan2vault >/dev/null 2>&1; then
    info "System user wan2vault already exists."
else
    useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin wan2vault
fi

install -d -o root -g wan2vault -m 0750 "$ETC_DIR"
install -d -o wan2vault -g wan2vault -m 0700 "$STATE_DIR"
install -d -o root -g root -m 0755 "$LIB_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; unset LOGIN_PASSWORD || true' EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
fetch_file() {
    local rel="$1" out="$2"
    if [ -f "$SCRIPT_DIR/$rel" ]; then
        cp "$SCRIPT_DIR/$rel" "$out"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RAW_BASE/server/$rel" -o "$out"
    else
        wget -qO "$out" "$RAW_BASE/server/$rel"
    fi
}

info "Installing server application."
fetch_file "wan2-vault.py" "$TMP_DIR/wan2-vault.py"
fetch_file "wan2-vault.service" "$TMP_DIR/wan2-vault.service"
python3 -m py_compile "$TMP_DIR/wan2-vault.py"
install -o root -g root -m 0755 "$TMP_DIR/wan2-vault.py" "$LIB_DIR/wan2-vault.py"
install -o root -g root -m 0644 "$TMP_DIR/wan2-vault.service" "$SERVICE_FILE"

SALT_HEX="$(openssl rand -hex 16)"
WRITE_TOKEN="$(openssl rand -hex 32)"
SESSION_SECRET_HEX="$(openssl rand -hex 32)"

PASSWORD_FILE="$TMP_DIR/.password"
printf '%s' "$LOGIN_PASSWORD" > "$PASSWORD_FILE"
chmod 0600 "$PASSWORD_FILE"
PASSWORD_HASH_HEX="$(python3 - "$SALT_HEX" "$PASSWORD_FILE" <<'PY'
import hashlib, pathlib, sys
salt = bytes.fromhex(sys.argv[1])
password = pathlib.Path(sys.argv[2]).read_bytes()
print(hashlib.scrypt(password, salt=salt, n=16384, r=8, p=1, dklen=32).hex())
PY
)"
rm -f "$PASSWORD_FILE"
unset LOGIN_PASSWORD

cat > "$ETC_DIR/config.json" <<EOF
{
  "public_hostname": "$PUBLIC_HOSTNAME",
  "bind_host": "127.0.0.1",
  "bind_port": 29444
}
EOF

python3 - "$ETC_DIR/auth.json" "$LOGIN_USERNAME" "$SALT_HEX" "$PASSWORD_HASH_HEX" <<'PY'
import json, sys
path, username, salt, pw_hash = sys.argv[1:]
with open(path, 'w', encoding='utf-8') as f:
    json.dump({
        'username': username,
        'salt_hex': salt,
        'password_hash_hex': pw_hash,
        'scrypt': {'n': 16384, 'r': 8, 'p': 1, 'dklen': 32},
    }, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY

cat > "$ETC_DIR/secrets.json" <<EOF
{
  "write_token": "$WRITE_TOKEN",
  "session_secret_hex": "$SESSION_SECRET_HEX"
}
EOF

chown root:wan2vault "$ETC_DIR"/*.json
chmod 0640 "$ETC_DIR"/*.json

info "Starting service."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 1
systemctl is-active --quiet "$SERVICE_NAME" || {
    systemctl status "$SERVICE_NAME" --no-pager || true
    fail "Service failed to start."
}

HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $PUBLIC_HOSTNAME" http://127.0.0.1:29444/)"
[ "$HTTP_CODE" = "200" ] || fail "Local self-test failed (HTTP $HTTP_CODE)."

printf '\n============================================================\n'
printf ' WeiG WAN2 Vault installed successfully\n'
printf '============================================================\n\n'
printf 'Hostname:      %s\n' "$PUBLIC_HOSTNAME"
printf 'Backend:       127.0.0.1:29444 (localhost only)\n'
printf 'WRITE_TOKEN:   %s\n' "$WRITE_TOKEN"
printf '\nSave the WRITE_TOKEN on your OpenWrt device. Do not publish it.\n'
printf 'It is also stored locally in: %s/secrets.json\n\n' "$ETC_DIR"
printf 'Next: create a Cloudflare Tunnel published application:\n'
printf '  Hostname: %s\n' "$PUBLIC_HOSTNAME"
printf '  Service:  http://127.0.0.1:29444\n\n'
printf 'No Nginx change, origin certificate, or new inbound VPS port is required.\n'

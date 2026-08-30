#!/bin/bash
set -euo pipefail

ETC_DIR="/etc/wan2-vault"
STATE_DIR="/var/lib/wan2-vault"
AUTH_FILE="$ETC_DIR/auth.json"
SECRETS_FILE="$ETC_DIR/secrets.json"
SESSIONS_FILE="$STATE_DIR/sessions.json"

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
[ -r "$AUTH_FILE" ] && [ -r "$SECRETS_FILE" ] || { echo "ERROR: WeiG-WAN2-Vault is not installed" >&2; exit 1; }

reset_login() {
    local username password password2 salt tmp password_file hash
    username="$(python3 - "$AUTH_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['username'])
PY
)"
    read -r -p "Login username [$username]: " new_username
    username="${new_username:-$username}"
    [ -n "$username" ] && [ "${#username}" -le 128 ] || { echo "Invalid username" >&2; return 1; }
    while :; do
        printf 'New login password (minimum 12 characters): '
        stty -echo; IFS= read -r password; stty echo; printf '\n'
        [ "${#password}" -ge 12 ] || { echo "Password is too short."; continue; }
        printf 'Confirm password: '
        stty -echo; IFS= read -r password2; stty echo; printf '\n'
        [ "$password" = "$password2" ] || { echo "Passwords do not match."; continue; }
        break
    done
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"; unset password password2 || true' RETURN
    password_file="$tmp/password"
    printf '%s' "$password" > "$password_file"
    chmod 600 "$password_file"
    salt="$(openssl rand -hex 16)"
    hash="$(python3 - "$salt" "$password_file" <<'PY'
import hashlib, pathlib, sys
salt=bytes.fromhex(sys.argv[1]); password=pathlib.Path(sys.argv[2]).read_bytes()
print(hashlib.scrypt(password,salt=salt,n=16384,r=8,p=1,dklen=32).hex())
PY
)"
    unset password password2
    python3 - "$AUTH_FILE" "$username" "$salt" "$hash" <<'PY'
import json, os, sys, tempfile
path, username, salt, h = sys.argv[1:]
obj={'username':username,'salt_hex':salt,'password_hash_hex':h,'scrypt':{'n':16384,'r':8,'p':1,'dklen':32}}
d=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix='.auth.',dir=d,text=True)
with os.fdopen(fd,'w',encoding='utf-8') as f:
    json.dump(obj,f,ensure_ascii=False,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o640); os.replace(tmp,path)
PY
    chown root:wan2vault "$AUTH_FILE"
    rm -f "$SESSIONS_FILE"
    systemctl restart wan2-vault.service
    echo "Login credentials updated. All browser sessions were revoked."
}

rotate_write_token() {
    local token
    token="$(openssl rand -hex 32)"
    python3 - "$SECRETS_FILE" "$token" <<'PY'
import json, os, sys, tempfile
path, token = sys.argv[1:]
with open(path,encoding='utf-8') as f: obj=json.load(f)
obj['write_token']=token
d=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(prefix='.secrets.',dir=d,text=True)
with os.fdopen(fd,'w',encoding='utf-8') as f:
    json.dump(obj,f,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o640); os.replace(tmp,path)
PY
    chown root:wan2vault "$SECRETS_FILE"
    systemctl restart wan2-vault.service
    echo
    echo "New WRITE_TOKEN: $token"
    echo "Update /etc/wan2-vault.conf on OpenWrt before the next report."
}

revoke_sessions() {
    rm -f "$SESSIONS_FILE"
    systemctl restart wan2-vault.service
    echo "All browser sessions revoked."
}

cat <<'EOF'
WeiG WAN Vault management

1) Change login username/password
2) Rotate WRITE_TOKEN
3) Revoke all browser sessions
4) Exit
EOF
printf 'Select [1-4]: '
read -r choice
case "$choice" in
    1) reset_login ;;
    2) rotate_write_token ;;
    3) revoke_sessions ;;
    *) exit 0 ;;
esac

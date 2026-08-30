#!/bin/bash
set -euo pipefail

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

if command -v cloudflared >/dev/null 2>&1; then
    cloudflared --version
    echo "cloudflared is already installed."
    exit 0
fi

command -v apt-get >/dev/null 2>&1 || {
    echo "ERROR: this helper supports Debian/Ubuntu apt systems only." >&2
    exit 1
}
command -v curl >/dev/null 2>&1 || {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl
}

install -d -m 0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg
cat > /etc/apt/sources.list.d/cloudflared.list <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
cloudflared --version

echo
echo "cloudflared installed."
echo "Create a remotely-managed Tunnel in the Cloudflare dashboard, then run the"
echo "'cloudflared service install <TUNNEL_TOKEN>' command Cloudflare provides."
echo "Do not publish the Tunnel token."

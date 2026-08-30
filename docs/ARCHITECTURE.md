# Architecture

## Data flow

```text
OpenWrt selected WAN
    |
    | HTTPS POST /api/v1/update
    | source forced to selected l3_device
    v
Cloudflare Edge
    |
    | CF-Connecting-IP
    | Cloudflare Tunnel
    v
cloudflared on VPS
    |
    v
127.0.0.1:29444
WeiG-WAN2-Vault
```

The server stores only the latest accepted IPv4 and the timestamp of the last accepted report.

The browser path is separate:

```text
Browser -> Cloudflare -> Tunnel -> 127.0.0.1:29444
```

The browser authenticates with username/password and receives a session cookie. OpenWrt never receives or uses the browser password.

## Authentication separation

- Browser: username/password -> session cookie.
- OpenWrt: independent WRITE_TOKEN -> update only.

The WRITE_TOKEN cannot be used as a browser session.

## Source verification

OpenWrt sends the WAN IPv4 read from netifd. The server also receives `CF-Connecting-IP` from Cloudflare. An update is accepted only if both IPv4 values are identical.

This is why the OpenWrt reporter binds curl to the selected WAN `l3_device`.

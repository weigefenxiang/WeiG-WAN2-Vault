# Troubleshooting

## Browser returns Cloudflare 502/Bad Gateway

Check the local service:

```bash
systemctl status wan2-vault --no-pager
ss -lntp | grep 29444
```

Expected bind address:

```text
127.0.0.1:29444
```

Check Tunnel:

```bash
systemctl status cloudflared --no-pager
```

Verify the published application points to:

```text
http://127.0.0.1:29444
```

## OpenWrt reports HTTP 401

The WRITE_TOKEN on OpenWrt does not match the VPS token.

Do not paste the token into an issue. Compare it locally.

## OpenWrt reports HTTP 403

Typical causes:

- the request did not reach Cloudflare with the same IPv4 OpenWrt posted;
- curl did not actually egress through the intended WAN interface;
- `CF-Connecting-IP` is missing because the endpoint is being accessed outside the intended Cloudflare path.

Inspect the OpenWrt interface dynamically:

```sh
ubus call network.interface.WAN2 status
```

## Login keeps expiring

Persistent browser sessions are renewed while they are used, but browsers can cap cookie lifetimes or delete site data. Clearing cookies will always require a new login.

## WAN status is stale

Check OpenWrt:

```sh
FORCE=1 /etc/wan2-ipnotify.sh
logread | grep wan2-vault | tail -20
```

Then check VPS service status.

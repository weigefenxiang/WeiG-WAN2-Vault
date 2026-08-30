# Troubleshooting

## Browser returns Cloudflare 502 / 521 / 522

Check the local service first:

```bash
systemctl status wan2-vault --no-pager
ss -lntp | grep 29444
```

Expected backend:

```text
127.0.0.1:29444
```

For Cloudflare Tunnel, also check:

```bash
systemctl status cloudflared --no-pager
```

For Cloudflare Proxy + Nginx, check Nginx syntax and local TLS/reverse-proxy routing.

## OpenWrt reports HTTP 401

The OpenWrt WRITE_TOKEN does not match the VPS token.

Do not paste the token into an issue or chat. Compare/replace it locally.

## OpenWrt reports HTTP 403

Typical causes:

- the update request did not egress through the WAN being reported;
- the posted IPv4 differs from Cloudflare's `CF-Connecting-IP`;
- `CF-Connecting-IP` is missing because the request bypassed Cloudflare.

Inspect a logical WAN:

```sh
ubus call network.interface.WAN2 status
```

Check detected WANs:

```sh
wan2-vault status
```

Force a diagnostic report:

```sh
wan2-vault report
logread | grep wan2-vault | tail -20
```

## A WAN is not detected in auto mode

Auto mode requires the interface to be `up`, have an IPv4 address, have an `l3_device`, and contain an IPv4 default route.

If the interface intentionally lacks a default route, it is not considered an Internet WAN by automatic discovery. Use manual mode only if that interface can really reach the Vault:

```sh
wan2-vault interfaces set WAN2
```

## A removed WAN still appears on the webpage

When at least one tracked WAN remains online, the next five-minute inventory change marks removed interfaces `Inactive`.

The record is intentionally retained so its last IP and change time remain available for troubleshooting.

## Five-minute cron does not produce log entries

This is expected when nothing changed. Unchanged checks are silent and do not contact Cloudflare/VPS.

## Login keeps expiring

Persistent browser sessions are renewed while they are used, but browsers can cap cookie lifetimes or delete site data. Clearing cookies always requires a new login.

## Upgrade fails

VPS:

```bash
sudo wan2-vault status
sudo wan2-vault rollback
```

OpenWrt:

```sh
wan2-vault status
logread | grep wan2-vault | tail -20
```

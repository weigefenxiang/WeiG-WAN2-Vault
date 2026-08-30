# Security model

WeiG-WAN2-Vault is designed so the OpenWrt router never needs a new inbound HTTP/HTTPS service.

## OpenWrt

The reporter makes outbound HTTPS requests only. Each WAN IPv4 update is bound to that WAN's `l3_device`.

The WRITE_TOKEN authenticates the device, while Cloudflare's `CF-Connecting-IP` proves which public IPv4 actually originated the request.

The server accepts an update only when:

```text
posted IPv4 == CF-Connecting-IP
```

Multi-WAN does not batch multiple public IPs into one update request because one connection can prove only one egress address.

## Inventory

`/api/v1/inventory` synchronizes interface names, devices and active/inactive state. It requires the WRITE_TOKEN and a request that reached the service through Cloudflare, but it never substitutes for the per-IP source match.

## Browser

The dashboard requires username/password authentication and a Secure, HttpOnly, SameSite=Strict session cookie.

Dashboard status endpoints are `no-store`.

The browser's selected WAN filter is kept only in `localStorage`; it does not modify OpenWrt reporting policy.

## Server

The application refuses non-loopback bind addresses. Public exposure should be provided by Cloudflare Tunnel or a local reverse proxy in front of the loopback backend.

Secrets live under `/etc/wan2-vault` and are not part of the repository.

## Failed reports

The server can record authenticated requests that reach it but fail validation, such as `source_mismatch`.

If OpenWrt loses connectivity before a request reaches the server, the server cannot know that attempt failed. Such failures remain visible only in OpenWrt logs.

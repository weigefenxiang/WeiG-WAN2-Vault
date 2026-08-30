# Architecture

WeiG-WAN2-Vault 1.1 is a multi-WAN design with a localhost-only server.

## Data path

```text
OpenWrt WAN/WAN2/WAN3
  -> per-interface HTTPS request bound to each l3_device
  -> Cloudflare Edge
  -> Cloudflare Tunnel OR Cloudflare-proxied reverse proxy
  -> 127.0.0.1:29444
  -> WeiG WAN Vault
```

The server never needs to listen on a public address.

## Why updates are per WAN

Each IP update is sent through the interface being reported. The server accepts the IP only when:

```text
JSON ip == CF-Connecting-IP
```

A single HTTP request cannot safely prove multiple egress IPs, so Multi-WAN uses one update request per changed interface.

## Five-minute checking

OpenWrt runs the reporter every five minutes, but normally performs only local `ubus` reads and persistent-state comparisons.

A network request occurs only when:

- a tracked interface is new;
- its IPv4 changes;
- its `l3_device` changes;
- the interface inventory changes;
- the administrator explicitly forces a report.

## State schema

The server stores schema 2:

```json
{
  "schema": 2,
  "interfaces": {
    "WAN2": {
      "ip": "203.0.113.10",
      "device": "pppoe-WAN2",
      "active": true,
      "changed_at": 1234567890,
      "last_report_at": 1234567890,
      "last_report_status": "success",
      "last_report_error": ""
    }
  },
  "last_inventory_at": 1234567890
}
```

v1.0 `{ip, updated_at}` state is read compatibly as `WAN2` and is written as schema 2 after the next state-changing request.

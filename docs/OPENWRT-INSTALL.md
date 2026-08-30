# OpenWrt Installation

## Requirements

The router must provide:

```text
ubus
jsonfilter
curl
```

No web server, DDNS package, Python runtime, or Node.js runtime is required on OpenWrt.

## Install

```sh
wget -O /tmp/wan2-vault-install.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/install.sh
sh /tmp/wan2-vault-install.sh
```

Enter your own hostname, logical OpenWrt interface name, and WRITE_TOKEN at install time.

Example logical interface:

```text
WAN2
```

The scripts do not hard-code a PPP device name or ISP-assigned IPv4. They query netifd dynamically:

```sh
ubus call network.interface.WAN2 status
```

and read:

```text
ipv4-address[0].address
l3_device
```

## Outbound interface binding

The reporter uses:

```sh
curl -4 --interface "$WAN_DEV" ...
```

This is an outbound client connection. It does not open TCP 443 on the router.

## Immediate events and recovery

Hotplug handles `ifup` and `ifupdate` for the selected interface.

A cron job runs every 10 minutes as a recovery mechanism. The reporter normally sends only when:

- the current IPv4 differs from the last successfully reported IPv4; or
- 30 minutes have elapsed since the last successful report.

This gives the dashboard a meaningful freshness signal and recovers automatically after temporary DNS, Cloudflare, VPS, or network failures.

## Logs

```sh
logread | grep wan2-vault
```

The logger does not intentionally print the WRITE_TOKEN or WAN IPv4.

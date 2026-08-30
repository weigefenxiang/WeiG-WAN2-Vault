# OpenWrt installation

## Requirements

```text
ubus
jsonfilter
curl
```

## Install

```sh
wget -O /tmp/wan2-vault-install.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/install.sh
sh /tmp/wan2-vault-install.sh
```

The installer lists current IPv4 default-route WAN candidates and asks for a tracking mode.

### Auto

Tracks every interface that is:

- `up`;
- has an IPv4 address;
- has an `l3_device`;
- has an IPv4 default route.

Recommended for routers where WAN ports may change.

### Manual

Track only named logical OpenWrt interfaces:

```sh
wan2-vault interfaces set WAN WAN2
```

Switch back to automatic discovery:

```sh
wan2-vault interfaces auto
```

## Schedule

The installer creates:

```text
*/5 * * * * /usr/bin/wan2-vault-report
```

The five-minute job does not blindly POST. State is stored in:

```text
/etc/wan2-vault-state/
```

If IPv4/device/inventory are unchanged, no Cloudflare or VPS request is made.

## Commands

```sh
wan2-vault status
wan2-vault version
wan2-vault report
wan2-vault interfaces
wan2-vault interfaces auto
wan2-vault interfaces set WAN WAN2
wan2-vault upgrade
```

`wan2-vault report` forces all currently selected WANs plus the inventory to be sent.

## v1.0 upgrade

```sh
wget -O /tmp/wan2-vault-update.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/update.sh
sh /tmp/wan2-vault-update.sh
```

For safety, a v1.0 `WAN_INTERFACE='WAN2'` configuration is migrated to manual tracking of WAN2 rather than suddenly uploading all other WAN interfaces.

After verifying the upgrade:

```sh
wan2-vault interfaces auto
```

## Logs

```sh
logread | grep wan2-vault
```

Unchanged five-minute checks are intentionally silent to avoid log spam.

# OpenWrt installation

## Requirements

```text
ubus
jsonfilter
curl
```

The OpenWrt scripts use BusyBox-compatible `cp`, `mkdir`, `chmod`, `mv`, `sed`, and `grep`; they do not require the separate `install` command from coreutils.

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

## Upgrade from older OpenWrt layouts

```sh
wget -O /tmp/wan2-vault-update.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/update.sh
sh /tmp/wan2-vault-update.sh
```

The updater supports both repository v1 installations and the earlier manual layout used before the repository installer existed.

Repository v1 may contain:

```text
/etc/wan2-vault.conf
WAN_INTERFACE='WAN2'
```

The earlier manual layout may contain:

```text
/etc/wan2-vault.token
/etc/wan2-vault.last-ip
/usr/bin/wan2-vault-report
/etc/hotplug.d/iface/95-wan2-vault
/etc/init.d/wan2-vault-report
```

For the manual layout, the updater reads the existing hostname/interface from the reporter and migrates the existing token without printing it. The new configuration is written to:

```text
/etc/wan2-vault.conf
/etc/wan2-vault-state/
```

For safety, an old single-WAN installation is migrated to manual tracking of the same interface instead of suddenly uploading every WAN. Obsolete hotplug/init/token files are removed only after the new layout is installed; if the updater fails, its backup/rollback path restores the previous files.

After verifying the upgrade:

```sh
wan2-vault interfaces auto
```

## Logs

```sh
logread | grep wan2-vault
```

Unchanged five-minute checks are intentionally silent to avoid log spam.

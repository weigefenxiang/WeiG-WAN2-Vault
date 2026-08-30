# WeiG-WAN2-Vault

一个面向 OpenWrt 多 WAN 动态公网 IPv4 场景的轻量私有 IP Vault。

OpenWrt 每 5 分钟只在本机检查 WAN 状态。**IPv4 或出口设备没有变化时不会向 Cloudflare/VPS 发请求**；发生变化时，每个 WAN 都通过自己的 `l3_device` 单独上报，因此服务端仍能校验：

```text
posted IPv4 == CF-Connecting-IP
```

网页登录后可以查看全部 WAN，也可以在下拉框中只显示某一个 WAN。页面显示精确的最后 IP 变化时间、最后上报时间、最近上报结果和页面刷新时间。

> 仓库本身不保存你的真实域名、用户名、密码、WRITE_TOKEN、VPS IP 或家庭 WAN IP。文档统一使用 `notify.example.com`。

## v1.1.0 highlights

- Multi-WAN：自动发现所有处于 `up`、有 IPv4、且拥有 IPv4 默认路由的 OpenWrt 接口。
- Manual mode：也可以只跟踪指定接口，例如 `WAN WAN2`。
- 每 5 分钟本地检查；状态不变时零上报。
- 每个 WAN 独立通过自己的 `l3_device` 上报，保留 Cloudflare 来源 IP 校验。
- 网页支持 `All WANs` / 单 WAN 选择，选择结果只保存在浏览器 `localStorage`。
- 显示 `Last IP change`、`Last report`、`Last report status`、`Page refreshed`。
- 接口消失后通过 inventory 同步为 `Inactive`，历史最后 IP 仍保留供排错。
- 服务端自动兼容并迁移 v1.0 单 WAN `current.json`。
- VPS 和 OpenWrt 都提供 `wan2-vault upgrade` 一键升级。
- VPS 升级前自动备份应用、service、版本和当前状态；失败自动回滚。
- OpenWrt v1.0 升级时保留原单 WAN 选择；需要多 WAN 时执行 `wan2-vault interfaces auto`。

## 架构

```text
OpenWrt
  ├─ WAN  ── curl --interface <WAN l3_device>  ─┐
  ├─ WAN2 ── curl --interface <WAN2 l3_device> ─┼─> Cloudflare ─> VPS
  └─ WAN3 ── curl --interface <WAN3 l3_device> ─┘

VPS
  └─ 127.0.0.1:29444
      └─ WeiG WAN Vault

Browser
  └─ https://notify.example.com
      ├─ login
      ├─ All WANs / selected WAN
      ├─ last IP change
      ├─ last report status/time
      └─ page refreshed time
```

服务端始终只监听 loopback：

```text
127.0.0.1:29444
```

公网入口有两种受支持方式：

1. **Cloudflare Tunnel**：Cloudflare Tunnel -> `http://127.0.0.1:29444`
2. **Cloudflare Proxy + Nginx**：Cloudflare -> VPS `443` -> Nginx/reverse proxy -> `http://127.0.0.1:29444`

两种方式都必须让后端收到 Cloudflare 设置的 `CF-Connecting-IP`。

## 1. VPS 安装

Debian/Ubuntu + systemd + Python 3：

```bash
curl -fsSLo /tmp/wan2-vault-install.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/install.sh

sudo bash /tmp/wan2-vault-install.sh
```

安装程序会询问：

```text
Public hostname: notify.example.com
Login username: ...
Login password: ********
```

安装结束会生成随机 `WRITE_TOKEN`。它只用于 OpenWrt 上报，不要提交到 GitHub、Issue 或聊天记录。

验证：

```bash
ss -lntp | grep 29444
```

必须只监听：

```text
127.0.0.1:29444
```

管理：

```bash
sudo wan2-vault status
sudo wan2-vault version
sudo wan2-vault check-update
sudo wan2-vault upgrade
sudo wan2-vault rollback
sudo wan2-vault manage
```

详见 [`docs/VPS-INSTALL.md`](docs/VPS-INSTALL.md)。

## 2. Cloudflare 入口

### 方案 A：Cloudflare Tunnel

仓库保留辅助安装脚本：

```bash
curl -fsSLo /tmp/install-cloudflared.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/install-cloudflared.sh

sudo bash /tmp/install-cloudflared.sh
```

Published application：

```text
Hostname: notify.example.com
Service:  http://127.0.0.1:29444
```

详见 [`docs/CLOUDFLARE-TUNNEL.md`](docs/CLOUDFLARE-TUNNEL.md)。

### 方案 B：Cloudflare Proxy + Nginx

适合 VPS 已经使用 Nginx `stream` / SNI 分流的场景。典型链路：

```text
Cloudflare HTTPS
    -> VPS :443
    -> nginx stream ssl_preread
    -> local TLS virtual host
    -> http://127.0.0.1:29444
```

Origin 侧建议使用 Cloudflare Origin CA + `Full (strict)`。

详见 [`docs/CLOUDFLARE-PROXY.md`](docs/CLOUDFLARE-PROXY.md)。

## 3. OpenWrt 安装

要求：

```text
ubus
jsonfilter
curl
```

安装：

```sh
wget -O /tmp/wan2-vault-install.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/install.sh

sh /tmp/wan2-vault-install.sh
```

安装器会列出当前检测到的 WAN 候选，然后选择：

```text
1) Auto   - 自动跟踪所有 IPv4 默认路由 WAN
2) Manual - 只跟踪指定接口
```

新安装推荐 `Auto`。

安装后：

```sh
wan2-vault status
wan2-vault interfaces
wan2-vault report
wan2-vault upgrade
```

切换为所有 WAN：

```sh
wan2-vault interfaces auto
```

只跟踪 WAN/WAN2：

```sh
wan2-vault interfaces set WAN WAN2
```

周期任务：

```text
*/5 * * * * /usr/bin/wan2-vault-report
```

这并不意味着每 5 分钟发请求。脚本先比较持久化本地状态：

```text
/etc/wan2-vault-state/
```

只有以下变化才需要网络请求：

- WAN 首次出现；
- WAN IPv4 改变；
- `l3_device` 改变；
- WAN 接口集合发生变化（inventory 同步）。

详见 [`docs/OPENWRT-INSTALL.md`](docs/OPENWRT-INSTALL.md)。

## 4. 多 WAN 上报安全模型

假设：

```text
WAN  = 1.1.1.1
WAN2 = 2.2.2.2
```

客户端不会把两个 IP 放进一次更新请求，而是分别：

```text
WAN:
curl --interface pppoe-WAN
POST {"interface":"WAN","device":"pppoe-WAN","ip":"1.1.1.1"}

WAN2:
curl --interface pppoe-WAN2
POST {"interface":"WAN2","device":"pppoe-WAN2","ip":"2.2.2.2"}
```

服务端分别验证请求携带的 IPv4 与 Cloudflare 实际看到的 IPv4 一致。这样支持 Multi-WAN 时不会降低 v1.0 的来源校验。

`/api/v1/inventory` 只负责同步接口名称/设备/Active 状态，不替代 IP 来源校验。

## 5. 网页状态

登录后默认显示全部 WAN：

```text
WAN
  IPv4               ...
  Device              ...
  Last report status  Success
  Last IP change      2026-08-30 18:20:00 · 24m ago
  Last report         2026-08-30 18:20:00 · 24m ago

WAN2
  ...

Page refreshed        2026-08-30 18:44:15
Current client IP     ...
```

顶部下拉框可以选择某一个 WAN。这个选择只保存在当前浏览器，不会改变 OpenWrt 上传哪些接口。

`Last IP change` 不会因为页面每 15 秒读取状态而改变，也不会因为 OpenWrt 每 5 分钟本地检查而改变。

## 6. 一键升级

### VPS

```bash
sudo wan2-vault upgrade
```

也可以继续使用独立更新脚本：

```bash
curl -fsSLo /tmp/wan2-vault-update.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/update.sh
sudo bash /tmp/wan2-vault-update.sh
```

升级不会覆盖：

```text
/etc/wan2-vault/
/var/lib/wan2-vault/sessions.json
```

升级前会备份当前应用、systemd service、版本和 `current.json`。安装后执行 Python 语法检查、systemd 重启和 localhost health check；失败会自动恢复。

手动回滚最近一次升级：

```bash
sudo wan2-vault rollback
```

### OpenWrt

```sh
wan2-vault upgrade
```

v1.0 的旧安装可以先运行新版 updater：

```sh
wget -O /tmp/wan2-vault-update.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/update.sh

sh /tmp/wan2-vault-update.sh
```

为了避免旧设备升级后突然开始上传额外 WAN，v1.0 的单 WAN 配置会迁移为 `manual`。确认后切换：

```sh
wan2-vault interfaces auto
```

## 7. v1.0 兼容

旧客户端仍可发送：

```json
{"ip":"203.0.113.10"}
```

服务端会把它视为：

```text
interface = WAN2
```

旧状态：

```json
{"ip":"203.0.113.10","updated_at":1234567890}
```

读取时自动映射到 schema 2，不要求手工编辑状态文件。

## 8. 卸载

VPS：

```bash
curl -fsSLo /tmp/wan2-vault-uninstall.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/uninstall.sh
sudo bash /tmp/wan2-vault-uninstall.sh
```

OpenWrt：

```sh
wget -O /tmp/wan2-vault-uninstall.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/uninstall.sh
sh /tmp/wan2-vault-uninstall.sh
```

## 项目目录

```text
WeiG-WAN2-Vault/
├── README.md
├── SECURITY.md
├── LICENSE
├── VERSION
├── server/
│   ├── install.sh
│   ├── install-cloudflared.sh
│   ├── update.sh
│   ├── manage.sh
│   ├── uninstall.sh
│   ├── wan2-vault
│   ├── wan2-vault.py
│   └── wan2-vault.service
├── openwrt/
│   ├── install.sh
│   ├── update.sh
│   ├── uninstall.sh
│   ├── wan2-vault
│   └── wan2-ipnotify.sh
├── docs/
└── tests/
```

## License

GPL-3.0. See [`LICENSE`](LICENSE).

# WeiG-WAN2-Vault

一个面向 OpenWrt 多 WAN IPv4 场景的轻量私有 IP Vault，同时支持**公网 WAN**与**私网/CGNAT WAN**。

OpenWrt 每 5 分钟只在本机检查 WAN 状态。**IPv4、出口设备和 WAN 接口集合都没有变化时，不会向 Cloudflare/VPS 发请求**；发生变化时，每个 WAN 都通过自己的 `l3_device` 单独上报。

网页登录后可以查看全部 WAN，也可以在下拉框中只显示某一个 WAN。页面会明确标注：

```text
Public / 公网
Private / 私网
```

在 `All WANs` 视图中，**Active 公网 WAN 优先显示，私网 WAN 排在公网 WAN 后面**。因此如果 `WAN2` 是公网、`WAN` 是私网，网页会先显示 `WAN2`。

> 仓库本身不保存你的真实域名、用户名、密码、WRITE_TOKEN、VPS IP 或家庭 WAN IP。文档统一使用 `notify.example.com`。

## Current highlights

- Multi-WAN：自动发现所有处于 `up`、有 IPv4、且拥有 IPv4 默认路由的 OpenWrt 接口。
- 同时记录公网 WAN 和 RFC1918/CGNAT 私网 WAN。
- Manual mode：也可以只跟踪指定接口，例如 `WAN WAN2`。
- 每 5 分钟本地检查；状态不变时零上报。
- 每个 WAN 独立通过自己的 `l3_device` 上报。
- 公网 WAN 保留严格的 Cloudflare 来源 IPv4 校验。
- 私网/CGNAT WAN 因为地址不可能等于 Cloudflare 看到的公网源地址，所以使用 WRITE_TOKEN 鉴权，并明确标记为 `Private`。
- 网页 `All WANs` 默认公网优先、私网靠后；也可选择单独 WAN。
- 显示 `Address type`、`Last IP change`、`Last report`、`Last report status`、`Page refreshed`。
- 接口消失后通过 inventory 同步为 `Inactive`，历史最后 IP 仍保留供排错。
- 服务端自动兼容并迁移 v1.0 单 WAN `current.json`。
- VPS 和 OpenWrt 都提供一键升级。
- VPS 升级前自动备份应用、service、版本和当前状态；失败自动回滚。
- OpenWrt 升级支持仓库 v1 安装和更早期的手工部署布局。
- OpenWrt 脚本使用 BusyBox 基础命令，不要求额外提供 coreutils `install` 命令。

当前版本见 [`VERSION`](VERSION)。

## 架构

```text
OpenWrt
  ├─ WAN  (Private) ─ curl --interface <WAN l3_device>  ─┐
  ├─ WAN2 (Public)  ─ curl --interface <WAN2 l3_device> ─┼─> Cloudflare ─> VPS
  └─ WAN3           ─ curl --interface <WAN3 l3_device> ─┘

VPS
  └─ 127.0.0.1:29444
      └─ WeiG WAN Vault

Browser
  └─ https://notify.example.com
      ├─ login
      ├─ All WANs / selected WAN
      ├─ Public / Private label
      ├─ public WANs first
      ├─ last IP change
      ├─ last report status/time
      └─ page refreshed time
```

服务端始终只监听 loopback：

```text
127.0.0.1:29444
```

公网入口支持两种方式：

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

典型链路：

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

脚本还会使用 OpenWrt/BusyBox 常见的 `cp`、`mkdir`、`chmod`、`mv`、`sed`、`grep`、`sort`。**不要求单独安装 coreutils `install`。**

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

Auto 模式不会排除私网 WAN。例如：

```text
WAN   172.20.x.x    pppoe-WAN     -> Private / 私网
WAN2  163.x.x.x     pppoe-WAN2    -> Public / 公网
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

## 4. 多 WAN 上报与校验模型

客户端不会把多个 WAN 放进同一个更新请求，而是分别通过对应 `l3_device` 发出：

```text
WAN:
curl --interface pppoe-WAN
POST {"interface":"WAN","device":"pppoe-WAN","ip":"172.20.10.2"}

WAN2:
curl --interface pppoe-WAN2
POST {"interface":"WAN2","device":"pppoe-WAN2","ip":"203.0.113.20"}
```

### 公网 WAN

公网 WAN 继续执行严格校验：

```text
posted IPv4 == CF-Connecting-IP
```

不一致时服务端返回：

```text
source_mismatch
```

并且不会覆盖上一次成功记录。

### 私网 / CGNAT WAN

RFC1918：

```text
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
```

以及 CGNAT：

```text
100.64.0.0/10
```

这类地址本身不可能等于 Cloudflare 看到的公网源 IP，因此不能使用 `posted IPv4 == CF-Connecting-IP` 进行证明。

对于这些接口，服务端要求：

```text
有效 WRITE_TOKEN
+ 请求必须经过 Cloudflare
+ OpenWrt 仍通过该 WAN 的 l3_device 发出请求
```

然后保存该私网 IPv4，并在网页明确显示：

```text
Private / 私网
```

这意味着：**公网 WAN 的 IP 有来源 IP 强校验；私网 WAN 的 IP 主要依赖 WRITE_TOKEN 和路由绑定，安全语义不同，网页会明确区分。**

`/api/v1/inventory` 只负责同步接口名称、设备和 Active 状态。

## 5. 网页状态与排序

登录后默认显示全部 WAN，并按以下顺序排序：

```text
1. Active + Public
2. Active + Private
3. Inactive + Public
4. Inactive + Private
```

同一组内按接口名排序。

例如：

```text
WAN2
  Active · Public
  IPv4               163.x.x.x
  Address type        Public / 公网
  Device              pppoe-WAN2
  Last report status  Success
  Last IP change      ...
  Last report         ...

WAN
  Active · Private
  IPv4               172.20.x.x
  Address type        Private / 私网
  Device              pppoe-WAN
  Last report status  Success
  Last IP change      ...
  Last report         ...
```

因此公网 `WAN2` 会显示在私网 `WAN` 上方。

顶部下拉框可以选择某一个 WAN。这个选择只保存在当前浏览器，不会改变 OpenWrt 上传哪些接口。

`Last IP change` 不会因为页面每 15 秒读取状态而改变，也不会因为 OpenWrt 每 5 分钟本地检查而改变。

## 6. 一键升级

### VPS

```bash
sudo wan2-vault upgrade
```

也可以运行独立更新脚本：

```bash
curl -fsSLo /tmp/wan2-vault-update.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/update.sh
sudo bash /tmp/wan2-vault-update.sh
```

升级不会覆盖 `/etc/wan2-vault/` 中的登录/Token 配置，也不会清除浏览器 Sessions。升级前会备份应用、systemd service、版本和 `current.json`，并在失败时自动恢复。

手动回滚最近一次升级：

```bash
sudo wan2-vault rollback
```

### OpenWrt

新版安装后直接：

```sh
wan2-vault upgrade
```

旧安装可先运行 updater：

```sh
wget -O /tmp/wan2-vault-update.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/openwrt/update.sh

sh /tmp/wan2-vault-update.sh
```

升级器支持两类旧布局。

仓库 v1 单 WAN 配置，例如：

```text
/etc/wan2-vault.conf
WAN_INTERFACE='WAN2'
```

以及更早期的手工部署，例如：

```text
/etc/wan2-vault.token
/etc/wan2-vault.last-ip
/usr/bin/wan2-vault-report
/etc/hotplug.d/iface/95-wan2-vault
/etc/init.d/wan2-vault-report
```

对早期手工部署，升级器会自动从旧 reporter 读取 hostname 和接口名，并迁移现有 Token，**不会把 Token 输出到终端**。

为了避免旧设备升级后突然开始上传额外 WAN，旧单 WAN会先迁移为：

```text
MODE='manual'
INTERFACES='原接口名'
```

确认后再切换：

```sh
wan2-vault interfaces auto
```

## 7. v1.0 API / 状态兼容

旧客户端仍可发送：

```json
{"ip":"203.0.113.10"}
```

服务端会把它视为 `WAN2`。

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

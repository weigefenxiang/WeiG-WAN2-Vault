# WeiG-WAN2-Vault

一个面向 OpenWrt 动态公网 IPv4 场景的轻量私有 IP 信箱。

它让 OpenWrt **主动**通过 HTTPS 把指定 WAN 接口的当前公网 IPv4 上报到 Cloudflare，再通过 Cloudflare Tunnel 转发到 VPS 上仅监听 `127.0.0.1` 的服务。浏览器访问自己的域名后，用用户名和密码登录即可查看当前 WAN IPv4。

> 仓库本身不需要，也不应该保存你的真实域名、用户名、密码、Tunnel Token、WRITE_TOKEN、VPS IP 或家庭 WAN IP。文档统一使用 `notify.example.com`。

## 设计目标

- OpenWrt 不新增 HTTP/HTTPS 入站服务。
- 不把家庭公网 IP 写进公开 DNS。
- VPS 后端只监听 `127.0.0.1:29444`。
- 使用 Cloudflare Tunnel，不要求为 Vault 新开 VPS 公网端口。
- Vault 不需要 Origin 证书、Certbot 或 acme.sh。
- OpenWrt 更新接口使用独立 WRITE_TOKEN，与网页登录密码隔离。
- OpenWrt 上报的 IPv4 必须与 Cloudflare 看到的 `CF-Connecting-IP` 一致。
- 只保存当前 WAN IPv4 和最后更新时间，不维护历史 IP 列表。
- 浏览器中的 WAN IP 响应使用 `Cache-Control: no-store`，不会缓存旧地址。
- “保持登录”采用长期 Session + 滑动续期；浏览器清除站点数据、主动退出或长时间不访问时仍可能要求重新登录。

## 架构

```text
OpenWrt WAN2
    |
    | outbound HTTPS only
    v
Cloudflare Edge
    |
    | Cloudflare Tunnel
    v
VPS cloudflared
    |
    v
127.0.0.1:29444
WeiG-WAN2-Vault

Browser
    |
    v
https://notify.example.com
    |
    +-- username/password login
    +-- persistent session
    +-- current WAN IPv4
```

这个项目不会在家庭 WAN 上监听 `80/443`。OpenWrt 的上报连接形态是：

```text
WAN_PUBLIC_IP:ephemeral-port -> Cloudflare:443
```

这是客户端主动出站连接，不是公网 HTTP Server。

## 1. VPS 安装

要求：Debian/Ubuntu + systemd + Python 3。

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

密码不回显，也不以明文保存。程序只保存 scrypt 密码哈希。

安装结束会生成一个随机 `WRITE_TOKEN`。它只用于 OpenWrt 上报，**不要提交到 GitHub、Issue、聊天记录或公开配置中**。

验证 VPS 后端：

```bash
ss -lntp | grep 29444
```

正确结果必须只监听：

```text
127.0.0.1:29444
```

不能是：

```text
0.0.0.0:29444
```

详细说明见 [`docs/VPS-INSTALL.md`](docs/VPS-INSTALL.md)。

## 2. 安装 cloudflared

可以使用仓库中的辅助脚本：

```bash
curl -fsSLo /tmp/install-cloudflared.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/install-cloudflared.sh

sudo bash /tmp/install-cloudflared.sh
```

然后在 Cloudflare Zero Trust / Tunnels 中创建 remotely-managed Tunnel。

Cloudflare 会给出类似下面的命令：

```bash
sudo cloudflared service install <TUNNEL_TOKEN>
```

`TUNNEL_TOKEN` 是秘密，不要写进仓库。

Published application：

```text
Hostname: notify.example.com
Service:  http://127.0.0.1:29444
```

不要再为这个 hostname 创建指向家庭 WAN IP 的 A/AAAA 记录。

详见 [`docs/CLOUDFLARE-TUNNEL.md`](docs/CLOUDFLARE-TUNNEL.md)。

## 3. OpenWrt 安装

要求 OpenWrt 已有：

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

安装程序会询问：

```text
Public hostname: notify.example.com
WAN interface [WAN2]:
WRITE_TOKEN: ********
```

`WRITE_TOKEN` 输入时不回显。

安装后会创建：

```text
/etc/wan2-vault.conf
/etc/wan2-ipnotify.sh
/etc/hotplug.d/iface/95-wan2-ipnotify
```

并安装周期检查：

```text
*/10 * * * * /etc/wan2-ipnotify.sh
```

脚本不会每 10 分钟无条件上报。默认在以下情况才 POST：

- WAN IPv4 发生变化；
- 上一次成功上报距今超过 30 分钟；
- 手动使用 `FORCE=1` 强制刷新。

第一次测试：

```sh
FORCE=1 /etc/wan2-ipnotify.sh
logread | grep wan2-vault | tail
```

详见 [`docs/OPENWRT-INSTALL.md`](docs/OPENWRT-INSTALL.md)。

## 4. 浏览器使用

打开：

```text
https://notify.example.com
```

第一次输入用户名、密码，并保持勾选：

```text
Keep me signed in until I log out
```

之后浏览器会保存一个 `Secure + HttpOnly + SameSite=Strict` 的长期 Session Cookie。服务会进行滑动续期，因此正常持续使用时基本等同于“保持登录直到主动退出”。

注意：浏览器可能限制持久 Cookie 的最长寿命，也可能因用户清理站点数据、隐私策略或长时间不访问而删除 Cookie。因此 Web 应用无法保证数学意义上的“永久不掉登录”。

WAN IPv4 本身不会被浏览器缓存，页面会周期读取最新状态。

## 5. 安全边界

家庭 OpenWrt：

```text
WAN:80            no service added
WAN:443           no service added
WAN HTTP API      none
WAN HTTPS API     none
IP reporting      outbound HTTPS only
```

运营商仍然天然知道它给你分配的公网 IP，也可能观察到你的线路连接 Cloudflare 的网络元数据。本项目解决的是：**不因为动态 IP 上报而在家庭 WAN 上增加一个可扫描的 HTTP/HTTPS 服务，也不通过公开 DNS 直接公布住宅 WAN IP。**

Cloudflare 作为代理方会处理客户端 IP 和请求元数据。不要把“不保存 IP 历史”等同于“Cloudflare 看不到任何网络元数据”。

更多内容见 [`SECURITY.md`](SECURITY.md) 和 [`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md)。

## 6. 更新

VPS：

```bash
curl -fsSLo /tmp/wan2-vault-update.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/update.sh
sudo bash /tmp/wan2-vault-update.sh
```

更新脚本不会覆盖 `/etc/wan2-vault` 或 `/var/lib/wan2-vault` 中的本地秘密和状态。

## 7. 卸载

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

## 8. 本地管理

在 VPS 上可以下载并运行管理脚本，用于修改登录密码、轮换 WRITE_TOKEN 或注销全部浏览器 Session：

```bash
curl -fsSLo /tmp/wan2-vault-manage.sh \
  https://raw.githubusercontent.com/weigefenxiang/WeiG-WAN2-Vault/main/server/manage.sh
sudo bash /tmp/wan2-vault-manage.sh
```

修改登录密码会自动注销现有浏览器 Session。轮换 WRITE_TOKEN 后，需要把新 Token 更新到 OpenWrt 的 `/etc/wan2-vault.conf`。

## 项目目录

```text
WeiG-WAN2-Vault/
├── README.md
├── SECURITY.md
├── LICENSE
├── VERSION
├── .gitignore
├── server/
│   ├── install.sh
│   ├── install-cloudflared.sh
│   ├── update.sh
│   ├── manage.sh
│   ├── uninstall.sh
│   ├── wan2-vault.py
│   └── wan2-vault.service
├── openwrt/
│   ├── install.sh
│   ├── uninstall.sh
│   ├── wan2-ipnotify.sh
│   └── 95-wan2-ipnotify
├── docs/
└── tests/
```

## Version

See [`VERSION`](VERSION).

## License

GPL-3.0. See [`LICENSE`](LICENSE).

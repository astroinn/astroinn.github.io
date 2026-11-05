---
title: "Nginx 反代内网 Home Assistant 的踩坑与排查记录"
date: 2026-03-07 19:57:00 +0800
categories: [Networking]
tags: [nginx, wireguard, home-assistant, websocket]
---

## 背景与网络拓扑

最近在折腾 Home Assistant (HA) 的外网访问。为了安全和方便，我没有选择直接进行端口映射，而是采用了如下的网络拓扑：

- **云服务器（公网节点）**：安装了 1Panel 面板，使用 OpenResty（Nginx）作为统一的反向代理入口。
- **组网方式**：通过 WireGuard 将云服务器与家里的局域网打通。
- **后端服务**：家里的 Home Assistant 运行在局域网（`192.168.6.1:8123`）。

外网用户访问云服务器域名 `https://ha.example.com` 后，Nginx 通过 WireGuard 隧道将请求转发到家里的 HA。

在此过程中，我踩了两个经典的坑：**Nginx 拦截导致的 SSL 握手失败** 和 **HA 手机 App 认证阶段的 WebSocket 断连**。特此记录排查过程。

---

## 踩坑一：Nginx IP 白名单导致的 `SSL_ERROR_SYSCALL`

为了进一步提升安全性，我在 Nginx 中配置了 IP 白名单，仅允许我所在省份（如湖北省 IP 段）以及 WireGuard 内网 IP 访问。

起初，我将 `allow` 和 `deny all;` 规则直接写在了 Nginx 的 `server { ... }` 块的最外层。
配置后，使用外部 IP 跑 `curl -I https://ha.example.com` 测试拦截效果时，并没有像预期那样返回 `403 Forbidden`，而是报了底层的 SSL 错误：

```bash
curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to ha.example.com:443
```

### 原因分析

Nginx 的执行机制决定了：在 `server` 级别进行 IP 拦截时，对于被拒绝的 IP，Nginx 会**在建立 TCP 连接后、尚未完成 SSL 握手之前就直接掐断连接**。因此客户端根本拿不到 HTTP 层面的 403 状态码，而是直接报底层连接重置。

### 解决方案

将 `allow` / `deny` 规则移到 `location ^~ / { ... }` 块内部即可。这样 Nginx 会先完成 SSL 握手，再在 HTTP 层面返回优雅的 `403 Forbidden`。

---

## 踩坑二：手机 App 登录断连 `Received close message during auth phase`

解决了 IP 拦截问题后，我用安卓端 Home Assistant App 登录，输入账号密码后一直转圈，最终登录失败。

查看家里的 HA 后台日志，发现了大量如下报错：
```log
[140570145081920] from 61.242.135.xx (Mozilla/5.0 ... Android 16 ... Home Assistant ...): Disconnected: Received close message during auth phase
```

日志显示，真实公网 IP 已成功透传（说明白名单和 `X-Forwarded-For` 配置没问题），但**在认证阶段（auth phase）底层连接被意外关闭了**。

### 排查过程

**1. 检查 WebSocket 请求头冲突**
Home Assistant 高度依赖 WebSocket。检查 Nginx 反代配置时，发现 1Panel 默认生成的配置和我手动添加的配置发生了冲突：
```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
...
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $http_connection; # 这一行覆盖了上面的硬编码 "upgrade"
```
由于某些客户端传来的 `$http_connection` 并不是标准的 `upgrade`，导致 WebSocket 握手失败。我清理了重复项，固定使用 `Connection "upgrade"`。但这依然没有彻底解决问题。

**2. 罪魁祸首：Nginx 的 `proxy_buffering` 与 WireGuard MTU**

结合 WireGuard 隧道跨网段反代的场景，终于定位到盲点：**Nginx 的代理缓冲（Proxy Buffering）机制**。

默认情况下 Nginx 会开启 `proxy_buffering`，将后端响应缓冲到本地内存或磁盘后再发给客户端。然而 **WebSocket 是要求高实时性的长连接数据流**——当请求穿过 WireGuard 这种带有封包/解包机制与特定 MTU 限制的 VPN 隧道时，缓冲机制极易导致 WebSocket 认证帧（Auth Frame）滞留缓冲区，最终触发客户端超时或 HA 服务端主动断开连接。

### 解决方案：关闭代理缓冲

在 Nginx 反向代理的 `location` 中显式关闭缓冲即可：

```nginx
proxy_buffering off;
```

---

## 最终 Nginx 配置

综合 IP 白名单、WebSocket 请求头、关闭代理缓冲三项优化，最终稳定运行的 Nginx `location` 配置如下：

```nginx
location ^~ / {
    proxy_pass http://192.168.6.1:8123;

    # -----------------------------------
    # 1. IP 访问控制 (白名单模式)
    # -----------------------------------
    allow 127.0.0.1;
    allow 192.168.0.0/16;   # 家里内网
    allow 10.0.0.0/8;       # WireGuard 等 VPN 网段
    include /www/sites/ha.example.com/hubei_ips.conf; # 引入指定省份的 IP 库
    deny all;

    # -----------------------------------
    # 2. WebSocket 长连接支持 (核心)
    # -----------------------------------
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400; # 维持 24 小时不断开

    # 【关键解决掉线问题】：关闭代理缓冲，防止 WebSocket 帧在 WireGuard 隧道中卡死
    proxy_buffering off;

    # -----------------------------------
    # 3. 真实 IP 透传
    # -----------------------------------
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

> 别忘了在 Home Assistant 的 `configuration.yaml` 中信任反代服务器 IP：
{: .prompt-warning }
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.6.x  # 你的 WireGuard Nginx 入口 IP
```

## 总结

1. **`allow` / `deny` 的放置层级**：放在 `server` 层会直接断 TCP（表现为 SSL 错误），放在 `location` 层则优雅返回 403。
2. **反代 Home Assistant 必做**：始终配置 `Upgrade` 和 `Connection "upgrade"` 以支持 WebSocket。
3. **跨 VPN/隧道反代**：遇到 WebSocket 应用频繁掉线时，第一时间加上 `proxy_buffering off;`，往往能药到病除。

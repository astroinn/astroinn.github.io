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

排查时遇到了两个现象：外部请求报 `SSL_ERROR_SYSCALL`，以及 HA 手机 App 在认证阶段断连。期间调整过 Nginx 配置，但这些调整都不是最终的解决办法。最后换用一个已在国内备案的域名，访问才恢复正常。下面按排查顺序记录。

---

## 现象一：外部请求报 `SSL_ERROR_SYSCALL`

为了进一步提升安全性，我在 Nginx 中配置了 IP 白名单，仅允许我所在省份（如湖北省 IP 段）以及 WireGuard 内网 IP 访问。

起初，我将 `allow` 和 `deny all;` 规则直接写在了 Nginx 的 `server { ... }` 块的最外层。
配置后，使用外部 IP 跑 `curl -I https://ha.example.com` 测试拦截效果时，并没有像预期那样返回 `403 Forbidden`，而是报了底层的 SSL 错误：

```bash
curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to ha.example.com:443
```

### 当时的排查

当时怀疑 IP 白名单的放置位置影响了请求，因此检查了 `allow`、`deny` 所在的配置块。不过，仅凭这条 `curl` 报错，无法确定断连发生在 Nginx 的哪个处理阶段，也无法证明白名单就是原因。

我尝试将规则移到 `location ^~ / { ... }` 中。这是排查时做过的配置调整，不能作为这次访问问题的最终解决方案。

---

## 现象二：手机 App 登录断连 `Received close message during auth phase`

调整白名单配置后，我用安卓端 Home Assistant App 登录，输入账号密码后一直转圈，最终登录失败。

查看家里的 HA 后台日志，发现了大量如下报错：
```log
[140570145081920] from 61.242.135.xx (Mozilla/5.0 ... Android 16 ... Home Assistant ...): Disconnected: Received close message during auth phase
```

日志记录了客户端公网 IP，也记录了连接在认证阶段关闭；它本身不足以证明白名单、转发头或 WebSocket 配置都正确。

### 排查过程

**1. 检查 WebSocket 请求头**
检查 Nginx 反代配置时，我看到 1Panel 生成的配置和手动添加的配置都设置了 WebSocket 相关请求头：
```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
...
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $http_connection;
```
我清理了重复的请求头配置，固定使用 `Connection "upgrade"`，但手机 App 登录问题仍然存在。原先将请求头冲突判定为断连原因，缺少足够的验证。

**2. 尝试关闭 Nginx 代理缓冲**

考虑到请求经过 WireGuard 隧道，我还尝试在反代的 `location` 中添加：

```nginx
proxy_buffering off;
```

这项改动也没有解决本次问题。此前关于代理缓冲、WireGuard MTU 导致认证帧滞留的分析没有得到验证，不能把它当成根因。

---

## 排查时使用过的 Nginx 配置

下面是排查时整理过的 Nginx `location` 配置，保留作记录。其中的白名单、请求头和缓冲设置都不代表这次问题的最终解决办法：

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
    # 2. 排查时保留的 WebSocket 相关设置
    # -----------------------------------
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400; # 读取上游响应的超时设置

    # 排查时尝试关闭代理缓冲；未证实能解决本次断连
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

排查时，Home Assistant 的 `configuration.yaml` 中也配置了反代服务器 IP：
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.6.x  # 你的 WireGuard Nginx 入口 IP
```

## 实际解决办法与总结

最后真正让访问恢复的，是换了一个**在国内已备案的域名**。换完之后，外网能正常打开 Home Assistant，手机 App 也能登录了。

回头看，前面调整白名单位置、清理 WebSocket 请求头、关闭代理缓冲，都是我排查时做过的尝试，但都没解决这次的问题。至于原来的域名具体在哪个环节出了问题，我手头的记录还不足以判断。先把这个结果记下来，免得以后再遇到类似现象时，又只盯着 Nginx 和 WireGuard 的配置看。

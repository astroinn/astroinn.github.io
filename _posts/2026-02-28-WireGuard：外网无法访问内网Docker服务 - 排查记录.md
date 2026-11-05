---
title: "WireGuard 外网无法访问 FNOS Docker 服务"
date: 2026-02-28 17:00:00 +0800
categories: [Networking]
tags: [wireguard, vpn, docker, fnos, iptables]
---

外网连上 WireGuard 后，我能打开 FNOS 页面，却打不开同一台 NAS 上映射到宿主机端口的 Docker 服务。这篇记录当时检查了哪些规则、尝试了什么，以及哪一步之后访问恢复正常。

## 先说结果

- **现象**：WireGuard 远端只能打开 FNOS 自身服务，映射到 Docker 的端口全部超时。
- **有效的改动**：在 iStoreOS 上为 WireGuard 来源、发往 LAN 接口的流量临时添加 `MASQUERADE` 规则后，Docker 服务可以访问了。
- **尚未证实的部分**：我此前也在 FNOS 的 `DOCKER-USER` 链添加了放行规则。单凭现有记录，无法判断它是否同样必要，也无法确定回包具体在哪一跳丢失。

## 环境信息

| 设备 | 说明 |
|---|---|
| **路由器** | iStoreOS（WireGuard 服务端） |
| **NAS** | FNOS（IP：`192.168.6.111`，运行 Docker 服务） |
| **VPN 网段** | `10.0.0.0/24` |
| **内网网段** | `192.168.6.0/24` |

---

## 问题描述

外网通过 WireGuard VPN 连接后：

- ✅ 可以访问 FNOS 页面（非 Docker 服务）
- ❌ 无法访问 FNOS 上的 Docker 服务（如 `:3000`、`:3001` 等端口）
- 错误表现：**响应时间过长（超时）**，而非连接被拒绝

---

## 排查过程

### 第一步：确认 VPN 网段

在 iStoreOS 上执行：

```bash
wg show | sed -n '1,8p'
```

```
interface: WireGuard
    listening port: 52525
peer: ...
    allowed ips: 10.0.0.10/32
```

这条输出说明该 peer 使用 `10.0.0.10/32`。本文后续使用的 `10.0.0.0/24` 是当时配置中的 VPN 地址段，不能仅由这条输出推断出来。

---

### 第二步：区分宿主机服务和 Docker 端口的流量路径

| 访问目标 | 流量路径 | 经过的链 | 结果 |
|---|---|---|---|
| FNOS 页面 | 到 FNOS 本机进程 | 通常经过 `INPUT` 链 | 可以访问 |
| Docker 映射端口 | 经 Docker 的端口映射转发到容器 | 可能经过 `FORWARD` 和 Docker 创建的链 | 访问超时 |

这提示我先检查 FNOS 的转发规则。Docker 的桥接网络和端口映射会创建自己的防火墙链，因此不能仅看 `FORWARD` 链的默认策略，还要看实际匹配到的规则及计数器。具体处理路径取决于网络模式和防火墙后端，参见 [Docker 官方文档](https://docs.docker.com/engine/network/firewall-iptables/)。

---

### 第三步：检查 FNOS 的 FORWARD 链

```bash
sudo iptables -L -n -v
```

```
Chain FORWARD (policy DROP)
```

这是 `FORWARD` 链的默认策略，不表示所有到容器的包都会被丢弃：如果前面的规则已放行，数据包就不会走到默认策略。这里还需要结合完整规则和计数器判断。

---

### 第四步：在 FNOS 的 DOCKER-USER 链添加放行规则

在使用 iptables 后端的 Docker 环境中，`DOCKER-USER` 用于放置先于 Docker 转发规则处理的用户规则。添加前应先确认实际源地址和已有规则。

```bash
sudo iptables -I DOCKER-USER -s 192.168.6.0/24 -j ACCEPT
```

添加后访问仍然超时。这只能说明单独添加这条规则没有解决问题，不能据此确认请求已进入容器。

---

### 第五步：观察规则计数器

通过监控 iptables 数据包计数：

```bash
watch -n 1 'sudo iptables -L DOCKER-USER -n -v && echo "---" && sudo iptables -L DOCKER -n -v'
```

当时看到相关规则的计数器变化，但浏览器依然超时。这表明有流量命中了规则；仅靠计数器还不能证明容器收到了请求，也不能断定回包丢在了哪里。接下来我转向 iStoreOS 的 NAT 规则。

---

### 第六步：检查 iStoreOS 的 NAT 规则

```bash
iptables -t nat -L zone_lan_postrouting -n -v
```

当时看到一条针对特定端口的 SNAT 规则，例如：

```
SNAT  tcp  --  10.0.0.0/24  192.168.6.111  tcp dpt:5666  to:10.0.0.1
```

没有看到 Docker 服务端口（如 `3000`、`3001`）对应的规则。这使我怀疑回程路由或源地址转换有问题，但仍需结合抓包或路由表才能确定具体原因。

---

### 第七步：临时添加 MASQUERADE 规则

在 iStoreOS 上执行：

```bash
iptables -t nat -I POSTROUTING -s 10.0.0.0/24 -o br-lan -j MASQUERADE
```

添加后，从 WireGuard 客户端访问这些 Docker 端口恢复正常。这是当时确认有效的一步。规则匹配 VPN 来源、经 `br-lan` 发出的流量，并非只针对某个 Docker 端口。

---

## 这次能确认什么

我能确认的结果是：添加 iStoreOS 的 `MASQUERADE` 规则前，访问 Docker 端口仍然超时；添加后，访问恢复正常。这支持“源地址转换或回程路径与故障有关”的判断，但不能单独证明 FNOS 的 `FORWARD` 默认策略就是根因，也不能确认回包具体在哪一跳丢失。

`MASQUERADE` 会把匹配流量的源地址改为路由器在出接口上的地址。这样做可能让回程流量按已有路径返回，但 FNOS 看到的就不再是客户端原本的 `10.0.0.x` 地址。如果以后需要保留真实客户端 IP，应进一步检查 FNOS 的返回路由，而不是直接照搬这条 NAT 规则。

## 规则持久化：先确认防火墙版本

上面的 `iptables -I` 命令是**临时测试**。原记录把向 `/etc/firewall.user` 追加同一条命令写成了通用的永久方案，这一点需要更正：OpenWrt 22.03 起默认使用 fw4（nftables）；`/etc/firewall.user` 是否加载、其中的 iptables 命令是否可用，都取决于实际版本和配置。仅仅追加文本并不能保证重启后生效。可先在 iStoreOS 上检查：

```bash
command -v fw4
command -v fw3
uci show firewall | grep -E 'include|fw4_compatible'
```

如果使用 fw4，应按 [OpenWrt 防火墙文档](https://openwrt.org/docs/guide-user/firewall/firewall_configuration)配置并验证持久化规则；如果使用旧版 fw3，也要确认 `/etc/firewall.user` 被引用，并在重启防火墙后核对规则是否还在。本文没有记录这台 iStoreOS 的具体防火墙版本或重启后的验证结果，因此不把临时命令写成已经验证的永久修复。

FNOS 上的 `DOCKER-USER` 放行规则也要按实际 Docker 防火墙后端检查，不能仅凭 `iptables-persistent` 已保存就认定重启后仍会按预期生效。这条规则放行整个 `192.168.6.0/24` 的转发流量，范围也比单个 Docker 服务更宽；若确认需要长期保留，应结合实际源地址、目标端口和网桥接口缩小匹配范围。

## 总结

这次排查最有用的线索是：宿主机服务可访问、Docker 映射端口超时，而在 iStoreOS 上临时添加源地址转换后访问恢复。`FORWARD` 默认 DROP、规则计数器增加和缺少某个端口的 SNAT 规则，都是排查线索，不足以单独证明完整的故障链路。后续若要把修复长期保留下来，还需要确认防火墙后端、规则加载方式，并在重启后复测。

---
title: "从远程桌面卡顿到 NAS 下载恢复：OpenWrt 回家链路排查与改造记录"
date: 2026-11-16 21:25:00 +0800
categories: [Networking]
tags: [openwrt, wireguard, tailscale, sing-box, vless, lucky]
description: "测速正常，远程桌面和 NAS 下载却很慢。从域名对照测试入手，记录通过 WSS 改造回家链路、再去掉内层 WireGuard 的排查过程。"
---

最近在外面远程家里的电脑，总觉得哪里不对劲。画面不流畅，操作断断续续，连打字都能感觉到延迟。我原本通过 Tailscale／WireGuard 访问家庭内网，家里有公网 IP，电信宽带的签约上行也有 50 Mbps，按之前的使用体验，不应该卡成这样。

于是我拿 NAS 文件下载做了一组对照。结果很有意思：普通访问很慢，换个域名却能接近跑满上行。之后又试着给 WireGuard 加上 WSS 外层，最后发现，日常访问 NAS 还可以把链路再简化一些。这篇就把当时怎么想、怎么测，以及最终留下什么方案记下来。

文中的传输速度统一使用 **MB/s**：50 Mbps 的签约上行约合 **6.25 MB/s**，最初记录的 3 Mbps 约合 **0.375 MB/s**。

## 测速正常，为什么远程访问还是这么慢

最先让我注意到问题的是远程桌面，但远程操作的“卡”不太容易量化。我又从外面下载家里的 NAS 文件，发现速度只有约 0.375 MB/s，部分 HTTPS 和 UDP 连接也一直处于比较低的速度。

与此同时，普通网络测速却完全正常，百度网盘上传也能用满上行。也就是说，家里的宽带并不是所有上传都慢。

这让我开始怀疑，不同类型的连接可能受到了不同处理。不过，测速正常还不能直接证明是运营商限速，远程桌面也可能受到延迟、丢包或连接路径的影响。我决定先抓住“同一个 NAS 文件，为什么有的访问方式快、有的慢”这个问题，找一个能反复比较的测试方法。

这里还要区分两个方向：**我在外面下载 NAS 文件，对家里的宽带来说，消耗的是上行带宽。** 外网客户端下载很慢，问题也可能出在家庭这一侧的上传链路。

## 第一个突破口：换成测试域名，下载速度上来了

查资料时，我看到有人提到：带有 `speedtest` 等测速相关特征的连接，可能被网络设备按不同方式处理。我就给同一 NAS 服务换用带有 `speedtest` 的子域名，实际试了一次。

普通域名下载约为 **0.375 MB/s**，换用测试域名后，HTTPS 下载能到 **5～6 MB/s**，已经接近这条宽带原本的上行水平。

这个结果给了我一个继续排查的方向：线路当时仍有接近跑满上行的能力，访问方式改变后，速度也确实变了。相比先去升级路由器或者调整一堆参数，我更想验证，能不能让其他回家流量也走这条加密 Web 连接。

但这里能确认的是我当时测到的差异，具体原因还没有查清。到底是 TLS 域名信息、DNS 关联，还是其他流量特征参与了识别，手头的证据不足以判断。网上关于“测速白名单”的说法可以作为测试线索，不能直接当作运营商已经确认的规则。

以后复测时，我会尽量固定文件、外部网络、目标 IP、端口，以及 IPv4／IPv6，只改变一个条件。否则，换域名时顺便换了路径，速度差异就很难解释了。

## 改造思路：先保留 WireGuard，换掉公网传输方式

原来的 WireGuard 已经能访问家庭内网，密钥、地址和路由也都配置好了。既然只是传输表现出了问题，我最初的想法是先保留它，在外面增加一层 WSS，看看能不能改善速度。

这里有个容易想当然的地方：**把 WireGuard 的 Endpoint 换成测试域名，不代表它就会发出 HTTPS 请求。** 域名最终只是被解析成 IP，WireGuard 仍按自己的协议发送 UDP 数据。[WireGuard 官方协议说明](https://www.wireguard.com/protocol/)也介绍了它的 UDP 报文与加密机制。

因此，两端都需要有对应的承载能力：手机把 WireGuard 数据交给外层代理，家里的入口解开外层，再把 UDP 数据送给本机 WireGuard。

家里的 OpenWrt 已经有公网 IP，可以直接接收连接。我就把职责分成三部分：

| 组件 | 在这条链路里的工作 |
|---|---|
| 手机 SFA | 接收应用流量，建立 WireGuard 与外层代理连接 |
| OpenWrt 上的 Lucky | 提供有效证书，接收 TLS 连接并反代 WebSocket |
| HomeProxy 管理的 sing-box | 处理代理认证，把数据转发给 WireGuard 或家庭内网 |

最终整理后的外层协议是 **VLESS＋WebSocket＋TLS**，文中简称 VLESS/WSS。先验证它能承载 WireGuard，再对比去掉内层 WireGuard 的表现；原有 OpenClash 继续运行。

## 保留内层 WireGuard：一个 SFA 完成整条连接

### SFA 是什么，为什么用它

[SFA](https://sing-box.sagernet.org/clients/android/) 是 **sing-box for Android**，也就是 sing-box 的安卓客户端。它可以通过 TUN 接收应用流量，再根据配置决定这些流量走哪个出口。

普通 WireGuard 客户端本身不会建立 WSS 连接，还需要配合其他承载工具。我这里使用 SFA，是因为它能够在一份配置中组合 WireGuard endpoint 和外层代理连接：手机上只启动一个客户端，就能完成这两层连接。

具体来说，访问家庭网段的流量先进入 SFA 内置的 WireGuard，再通过外层 VLESS/WSS 发回家。其他流量继续走手机原来的网络。sing-box 的 [WireGuard endpoint](https://sing-box.sagernet.org/configuration/endpoint/wireguard/) 和 [连接串联字段](https://sing-box.sagernet.org/configuration/shared/dial/)提供了这种组合所需的配置能力。

这里用的是现有 WireGuard Peer，并不是把整个 Tailscale 客户端放进 WSS。原来的组网是问题背景，后续测试使用的是单独配置的 WireGuard 链路。

### 数据到底经过哪些层

按照最终 VLESS 方案整理，完整链路如下：

```text
手机应用访问 NAS
        ↓
SFA TUN 接收家庭网段流量
        ↓
SFA 内置 WireGuard 加密，生成 UDP 数据
        ↓
VLESS 承载 UDP → WebSocket＋TLS
        ↓
公网 WSS 连接
        ↓
OpenWrt 上的 Lucky 终止 TLS、反代 WebSocket
        ↓
sing-box 解开 VLESS，转发至本机 WireGuard UDP 端口
        ↓
OpenWrt WireGuard 解密并转发
        ↓
NAS／家庭内网服务
```

Lucky 负责外层 TLS，WireGuard 的加密数据仍要交给两端的 WireGuard 处理。回包沿这条连接反向返回。

这条链路接通后，可以正常访问路由器和 NAS。排查阶段测得，带内层 WireGuard 的 WSS 组合下载约为 **3 MB/s**，比最初约 0.375 MB/s 好了不少。

不过，直接 HTTPS 能到 5～6 MB/s，套上 WireGuard 后只有约 3 MB/s，差距还在。既然外层 Web 连接已经能用，我接着想：如果只是从外面访问 NAS，内层 WireGuard 是否必须保留？

## 去掉内层 WireGuard，再做一次对照

下一步没有继续盲调 MTU，而是先绕过 WireGuard：保留外层 WSS，把家庭网段的流量直接交给 sing-box，再由它访问 NAS。

这样少了一次 WireGuard 加解密和隧道转发，路径变成：

```text
手机应用 → SFA TUN → WSS 代理 → Lucky → sing-box → NAS
```

我继续下载同一个文件，记录到的结果如下：

| 访问方式 | 排查阶段记录的下载速度 |
|---|---:|
| 原普通域名访问 | 约 0.375 MB/s |
| 测试域名直接 HTTPS 下载 | 5～6 MB/s |
| WireGuard 经 WSS 访问内网 | 约 3 MB/s |
| WSS 代理直接访问内网 | 5～6 MB/s |

去掉内层 WireGuard 后，下载恢复到 **5～6 MB/s**，接近直接 HTTPS 的水平。对我日常下载文件、打开 NAS 网页这些需求来说，简化链路确实更合适。

需要说明，表中是排查阶段的历史测量，外层代理后来才统一为 VLESS。最终 VLESS 配置已经验证内网可达，但没有另外留下同条件的测速记录，因此这里不把这组速度写成 VLESS 的独立性能测试。

至于多出来的开销具体来自哪里，我没有逐项测完。WireGuard 的额外加密与封装、手机和路由器的数据处理、MTU，以及在 TCP 连接里承载隧道时的传输表现，都可能有影响。现有对照能够帮助我选择更合适的日常链路，还不足以把差距归结到某一个参数上。

同样，这个结果比较的是“WireGuard 经 WSS”和“WSS 代理直接转发”，不能用来判断原生 UDP WireGuard 的速度。

## 最后留下的两种使用方式

最终我把服务端入口统一为 VLESS/WSS，保留两条链路，按用途切换。

平时访问 NAS 网页、下载文件，或者通过内网 IP 使用服务，就直接走：

```text
手机 SFA → VLESS/WSS → Lucky → sing-box → NAS
```

这条链路配置比较简单，不需要再维护手机端的 WireGuard 隧道地址和密钥。服务端按目标地址限制可访问范围，客户端只把家庭网段流量送回家。

如果需要 WireGuard 的独立隧道地址，或者想沿用按 Peer 管理设备的方式，则使用：

```text
手机 SFA 内置 WireGuard
    → VLESS/WSS → Lucky → sing-box
    → OpenWrt WireGuard → 家庭内网
```

两条最终链路都已经验证能访问家庭内网。这里说的“能访问”，主要是主动连接路由器和 NAS 服务；设备自动发现、广播和两地网段双向互访，还需要另行设计。

回头看，这次最有用的并不是一次改了多少配置，而是每一步都有一个可以比较的结果：先确认家里的上行能力还在，再比较域名差异；接着验证 WSS 能不能承载回家流量，最后通过绕过内层 WireGuard，找到更适合日常 NAS 访问的方式。

最初让我开始排查的是远程桌面卡顿，目前明确留下的是 NAS 下载速度改善的记录。远程桌面的实际操作体验、延迟和丢包，还需要单独复测。我先把已经验证的部分记下来，后面有结果再补。

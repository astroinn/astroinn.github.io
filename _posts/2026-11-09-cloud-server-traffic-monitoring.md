---
title: "从自动关机到分级告警：云服务器月度流量监控改造记录"
date: 2026-11-09 14:14:00 +0800
categories: [Networking]
tags: [aliyun, cdt, linux, systemd, traffic-monitoring]
description: "记录香港云服务器流量监控的统计口径、旧脚本问题、企业微信告警改造，以及低内存定时程序的部署与验证。"
---

我有一台配置很小的香港云服务器，想在每月免费公网流量用完前收到提醒。原来机器上有个达到阈值就关机的脚本，但检查后发现，它的统计方法和我理解的额度都存在偏差。这次索性从计费口径开始梳理，最后换成每小时检查、分四档发送企业微信消息的程序。把过程记下来，方便以后排查和重装。

## 先弄清楚要监控什么

起初我以为每月的 220 GB 免费流量可以按访问者所在地区拆开统计，于是考虑按目的 IP 区分中国内地和其他地区。核对[阿里云 CDT 公网流量说明](https://help.aliyun.com/zh/cdt/internet-data-transfers/)后才发现：**20 GB 和 200 GB 对应的是云资源所在地域，不是访问者的位置**。这台服务器在香港；如果实例符合 CDT 免费额度的适用条件，其公网出站流量使用非中国内地地域的 200 GB 额度，即使流量发往中国内地，也不会改用内地的 20 GB 额度。

还有两个限制也得记住：免费额度按账号共享，并非每台服务器各有 200 GB；这里计算的是符合条件的公网**出方向**流量。因此，单靠这台机器的网卡计数，只能做本机预警，不能代表整个账号的 CDT 剩余额度。实际计费仍要以[CDT 控制台和账单](https://help.aliyun.com/zh/cdt/query-bills)为准。

## 旧脚本为什么不能直接用

最早检查的是 `/root/aliyun_traffic.sh`。它累计 `eth0` 的发送字节数，达到阈值后等待五分钟再关机。脚本注释里写着 GB，但代码使用 `1024³` 换算，所谓的 199 GB 实际上是 **199 GiB，约 213.67 GB**。如果按十进制的 200 GB 额度做预警，这个阈值已经太晚。

旧脚本还有几处实际问题：

- 首次运行或跨月时把“上次网卡读数”清零，下一次却读取网卡自启动以来的总发送量，可能把以前的流量重新算进本月。
- 没有运行锁，重复触发时可能同时修改累计文件；尤其在等待关机的五分钟内。
- 脚本权限是 `777`，由 root 执行时不适合让其他本地用户也能改写。
- 旧数据停在 2026 年 3 月，无法据此还原 11 月已经用掉多少流量。

我更需要的是提前知道流量接近上限，而不是依赖一个可能误算的脚本直接关机，于是改为**只告警、不自动关机**。

## 第一版：Python 脚本每分钟检查

第一版从 2026 年 11 月 9 日 **13:20（北京时间）**开始，以当时的网卡计数作为基线，读取 `eth0` 出站量并保存本月累计值。最初设为达到 180 GB（200 GB 的 90%）时向企业微信机器人发送消息；发送成功后当月不重复发送，失败则留待下次重试。脚本和配置后来移到了 `/root`。

这里有一个容易忽略的边界：**13:20 之前的本月流量没有被自动补入**。如果需要和账单更接近，得从云平台核对已用量后手动设置基线。网卡的全部发送字节还可能包含内网流量，和 CDT 的计费口径也不完全相同。

实际发送过企业微信测试消息，接口返回成功。普通采样测得 Python 进程的内存峰值约 **16.6 MiB**。它是定时启动、执行完退出的，并非常驻进程；不过这台服务器只有约 **451 MiB** 内存、系统盘约 **1.9 GB**，我还是想把单次检查开销再降一些。

期间 SSH 曾在身份验证前被远端关闭，排查后又恢复连接，具体原因没有确认。这段断连没有被当作流量程序的故障。磁盘检查时先清理了可重新生成的 APT 缓存，释放约 62 MB；这也没有改变流量统计逻辑。

## 最终方案：编译程序，每小时分级提醒

比较了 Shell 脚本和编译程序的维护成本后，我把监控改写为 C 程序，并将检查频率调为**每小时整点一次**。运行时读取 `eth0` 发送计数，计算本月增量，保存状态，再判断是否达到告警档位；只有要发消息时才启动 `curl`。每次运行结束后进程退出。

| 月额度使用比例 | 本机累计出站量达到 |
|---|---:|
| 70% | 140 GB |
| 80% | 160 GB |
| 90% | 180 GB |
| 95% | 190 GB |

这里的 GB 按**十进制**计算，即 `1 GB = 1,000,000,000` 字节。每档每月成功通知一次；如果两次采样间跨过多档，程序会依次补发未成功的档位。发送失败的档位留到后续检查重试，已经成功的档位不会重复发送。只有 HTTP 状态为 200 且企业微信接口返回 `errcode: 0`，才标记为成功。

服务器系统时间显示为 UTC，程序按 `Asia/Shanghai` 判断月份，不需要为了显示北京时间而修改系统时区。跨月时会清除上月的告警标记。旧版 Python 的累计字节、网卡基线、首次启用时间和告警状态已经迁入新版状态文件，迁移时没有从零重新累计。

### 定时任务怎么运行

最终由 systemd 的 `.timer` 决定运行时间，`.service` 启动一次程序。定时器的关键配置如下：

```ini
[Timer]
OnCalendar=*-*-* *:00:00
AccuracySec=1s
Persistent=true
Unit=aliyun-traffic-alert.service
```
{: file='/etc/systemd/system/aliyun-traffic-alert.timer' }

服务使用 `Type=oneshot` 和 `ExecStart=/root/aliyun-traffic-alert`。它每次做完采样就退出，所以服务显示 `inactive (dead)` 并不等于定时器失效；需要看 timer 是否处于 active 状态，以及上次执行结果。`Persistent=true` 用于在错过日历触发后补执行一次，不能理解成逐小时补跑。

程序与配置的最终位置：

| 用途 | 路径 |
|---|---|
| 可执行程序 | `/root/aliyun-traffic-alert` |
| C 源码 | `/root/aliyun-traffic-alert.c` |
| 配置 | `/root/aliyun-traffic-alert.conf` |
| 累计状态 | `/var/lib/aliyun-traffic-alert/state-v2.dat` |
| 跨月汇总 | `/var/lib/aliyun-traffic-alert/monthly-history.log` |
| 定时器与服务 | `/etc/systemd/system/aliyun-traffic-alert.{timer,service}` |

配置中 `quota_bytes=200000000000`、`gb_bytes=1000000000`、`interface=eth0`，分别对应 200 GB 月额度、十进制 GB 和统计网卡。配置每次运行都会重新读取；**修改告警档位或月额度**则还要检查已有的去重标记是否仍与新规则对应。企业微信 Webhook 写在当前 C 源码顶部，源码与编译出的程序都包含真实密钥，因此没有把它们上传到公开博客。

### 我怎么确认它正常工作

在 Debian 10 / GCC 8.3 环境编译后，隔离测试覆盖了累计、重启、网卡计数归零、北京时间跨月、四档边界、跨档补发、去重、发送失败重试、状态损坏和并发锁等情况。真实企业微信测试消息发送成功；**14:00 的整点自动运行也成功**，下次计划执行时间显示为 15:00。

普通采样单次测得进程内存峰值约 **0.72 MiB**；实际通知时 `curl` 子进程峰值约 **10.68 MiB**。这些是当时机器上的测量结果，不是固定上限。后续清理了部署暂存、旧 Python 版、旧状态和测试工具；按我的要求，旧版备份也已删除。最终仍保留在用程序、源码、配置及 `state-v2.dat`，每小时任务正常。

## 以后查看与维护

日常查看当前累计、各档状态和最近采样时间：

```bash
/root/aliyun-traffic-alert --status
```

检查定时器、服务和日志：

```bash
systemctl cat aliyun-traffic-alert.timer
systemctl cat aliyun-traffic-alert.service
systemctl list-timers aliyun-traffic-alert.timer
systemctl show aliyun-traffic-alert.service -p Result -p ExecMainStatus
journalctl -u aliyun-traffic-alert.service -n 50 --no-pager
```

`Result=success`、`ExecMainStatus=0` 表示最近一次服务执行成功。手动采样但不发送告警，可以运行：

```bash
/root/aliyun-traffic-alert --sample-only --memory
```

如果要从源码重新编译，服务器上的命令是：

```bash
gcc -std=c11 -Os -Wall -Wextra -Werror -Wformat=2 \
  -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE -pie \
  -Wl,-z,relro,-z,now \
  -o /root/aliyun-traffic-alert.new /root/aliyun-traffic-alert.c
strip /root/aliyun-traffic-alert.new
chmod 700 /root/aliyun-traffic-alert.new
mv /root/aliyun-traffic-alert.new /root/aliyun-traffic-alert
```

不要随手删除 `state-v2.dat`：它保存着本月累计和告警去重状态。需要补入已用量时，先对照云平台数据与十进制 GB 单位，再使用 `--set-month-used-gb`；该操作会重建网卡基线并清除当月告警标记，之后要检查下一次告警行为。

## 这套监控的边界

最终方案解决的是“及时提醒我查看额度”，并不能保证绝不产生超额费用。每小时检查一次，告警最多可能晚接近一小时；跨月边界的流量也可能整体计入新月。重启或网卡计数归零后，最后一次采样到归零之间的流量无法还原。企业微信发送成功、状态尚未写入时如果程序中断，重试还可能出现重复消息。

最关键的口径差异仍在：`eth0` 计的是本机网卡发送量，可能包含内网流量；账号下其他资源的消耗又完全不在这里。以后看到告警，我会去 CDT 控制台核对账单，而不是把脚本显示的数字当作可用额度余额。

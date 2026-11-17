# 只让指定目标走 VPN：路由分流的完整做法

## 问题

MotionPro 连接后会：

1. 删掉物理网卡的默认路由；
2. 把 `0.0.0.0/0` 指向 VPN 网关；
3. 把 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 也指到 VPN。

结果所有流量都走校园网（全局模式），而且**手工加回默认路由会被自动删掉**。

## 为什么会被抢回

`vpnd.exe` 有路由监控线程，检测到默认路由不是 VPN 就重新接管。
开关在注册表：

```text
HKLM\SOFTWARE\VPN\VPN2\SSTPRouteMonitorOff = 1
HKLM\SOFTWARE\WOW6432Node\VPN\VPN2\SSTPRouteMonitorOff = 1
```

**该值只在连接时读取**。所以：

- 只在连接后改，下一次它仍会接管；
- 想让它一直生效，必须在**连接前**写入，然后重连。

实测：连接后改路由 → 4 秒内被打回；先置开关 + 重连 + 再改路由 → 稳定。

## 分流顺序（必须按这个顺序）

1. 记录/取得物理网卡与网关
   （VPN 连接后默认路由已被删，可以从 `Get-NetIPConfiguration` 或邻居表反推；
   脚本还会把结果缓存到 `%LOCALAPPDATA%\tongji-motionpro-vpn\state.json`）；
2. 加物理默认路由：`0.0.0.0/0 via <物理网关> metric 10`；
3. 给目标加 VPN 路由：
   - 网段：`10.67.0.0/16 via <VPN 网关>`
   - 域名：解析出 `/32` 后逐条加
   - 校内 DNS：`202.120.190.208/32` 等，否则域名解析会走公网出口失败
4. 删掉 VPN 网卡上的默认路由；
5. 删掉 VPN 网卡上残留的 `192.168.*`、`172.16-31.*` 等本地网段路由
   （保留第 3 步的目标，否则会把目标自己也删了）；
6. 置 `SSTPRouteMonitorOff=1`，供下次连接使用。

## 为什么要把校内 DNS 指到 VPN

内网域名（如 `hpc.example.edu.cn`）只在校园 DNS 里有记录。VPN 连上后系统
DNS 会变成校内 DNS，但如果 DNS 服务器的路由走了公网出口，查询会被丢弃，
表现为“能 ping 通 IP、解析不了域名”。

## 每次重连后都要重新分流

重连时 MotionPro 会重新下发路由。`SSTPRouteMonitorOff` 只保证它不再持续抢，
不保证它不重新下发。所以连接动作完成后要再跑一次 `split-vpn.ps1 on`。

## 权限

改路由、改 HKLM 都需要管理员。脚本用 `-Elevate` 弹 UAC：

```powershell
Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'on'
```

提权后是**新进程**，父进程拿不到它的输出；脚本会把结果写进状态文件，
父进程再 `status` 一次即可确认。

## 回滚

分流失败（目标不通、默认路由没恢复）时脚本自动 `off`：

- 删掉目标路由；
- 把默认路由加回 VPN（恢复全局模式）。

这样最坏情况是“所有流量走 VPN”，而不是断网。

## 目标网段包含 VPN 服务器自身时：必须钉住隧道端点

把整个学校公网段（如 `202.120.0.0/16`）导进 VPN 时，VPN 网关
`202.120.189.34` 也在这个网段里。隧道自己的 TCP 连接如果按新路由走，
就会被送进隧道内部，形成环路（连上即断）。

做法：给 `vpn.<school>` 的每个 A 记录加 `/32` 路由指向物理网关，
优先级高于网段路由：

```powershell
Resolve-DnsName vpn.example.edu.cn -Type A | ForEach-Object IPAddress |
  ForEach-Object { New-NetRoute -DestinationPrefix "$_/32" -InterfaceIndex $physIf -NextHop $physGw -RouteMetric 1 }
```

同时在清理时把指向错误网关的同名 `/32` 删掉，避免历史脏路由。

## IPv6 会绕过隧道

VPN 只有 IPv4。`www.<school>.edu.cn` 这类站点常同时有 AAAA 记录，
系统默认优先 IPv6，于是流量走本地宽带直连，看起来“没走 VPN”。

两种处理：

1. 系统层：`netsh interface ipv6 set prefixpolicy ::ffff:0:0/96 60 4`
   （默认是 `35 4`；管理员权限；`off` 时改回去）；
2. 代码层：强制 IPv4，例如把 `socket.getaddrinfo` 的 `family` 固定为
   `AF_INET`，或在 curl 里加 `-4`。

注意浏览器可能仍有自己的解析偏好，验证时用 `curl -4` 和 `curl` 各看一次
`remote_ip`。

## 验证清单

- `0.0.0.0/0` 只有一条，指向物理网卡；
- 目标网段/`/32` 指向 VPN 网卡；
- 目标站点 HTTP 200，`remote_ip` 是内网地址；
- 公网站点仍 200；
- 断开 VPN 后目标不通（说明确实依赖隧道）。

## 与系统代理的冲突

分流之后，`10.x` / `192.168.x` 走 VPN 网卡。但如果系统开了 HTTP 代理
（Clash 等），Python 的 `requests` 会把请求交给代理，代理再回连本机，
出现 `ConnectionAbortedError(10053)`。`curl` 不读 Windows 系统代理，所以
“curl 通、Python 不通”。解决：`session.trust_env = False`。

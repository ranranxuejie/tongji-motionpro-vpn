# 常见故障对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| `无法加载文件 … 因为在此系统上禁止运行脚本` | PowerShell 执行策略是 `Restricted` | 用同目录 `.cmd` 包装，或 `powershell -NoProfile -ExecutionPolicy Bypass -File`；不要要求用户改系统设置（组策略下发的改不动） |
| 连接要等 60~90 秒 | 客户端升级检查超时 | 正常现象；`up` 的 `-TimeoutSec` 默认 180 足够 |
| `VPN status is connecting or connected, no need connect repeatable.` 然后退出 | 注册表状态残留（上次被强杀） | 清 `HKCU\Software\VPN\VPN2` 的 `VPNstatus`/`status`/`MPCommandLineFlag` 为 0，再连 |
| `Login fails. Please check your username and password.` | 账号/密码错，或账号被锁 | 用 GUI 登一次确认；看日志 `_uname=` 是否是自己 |
| 连上但立刻断，日志 `error = 41` | 会话被服务端注销（另一处登录/超时） | 重新 `up`；避免多设备同时在线 |
| 目标站点 200，但 `remote_ip` 是公网地址 | 该域名有公网解析，请求没走 VPN | 检查是否加了对应网段/`/32` 路由；确认 DNS 用的是校内解析 |
| 域名解析不到内网 IP | DNS 走了公网出口 | 把校内 DNS 的 `/32` 指到 VPN 网卡 |
| 分流 4 秒后被打回全局 | `SSTPRouteMonitorOff` 没在连接前生效 | 先置注册表 → `-Reconnect` → 再 `on` |
| `curl` 能访问，Python `requests` 报 `ConnectionAbortedError(10053)` | 系统代理（Clash 等）劫持内网请求 | `requests.Session().trust_env = False`，或 `NO_PROXY=tongji.edu.cn,10.67.0.0/16,...`，或在代理软件里把这些域名/网段设为 DIRECT |
| `openconnect --protocol=array` 登录失败 | Array 协议只支持用户名密码，网关要短信/OTP | 改用 MotionPro 本体（命令行或容器） |
| `openconnect` 报 DTLS 相关错误 | Array 协议只支持 DTLSv1.0，系统可能禁用 | `--no-dtls` 退回 TCP |
| WSL 里连不上 | IBM 文档明确 WSL1 能认证但建不起隧道 | 用 WSL2（需 `/dev/net/tun`）或原生 Windows |
| 改路由提示拒绝访问 | 没有管理员权限 | `-Elevate` 弹 UAC，或用管理员 PowerShell |
| `Find-NetRoute` 报找不到对象 | 该地址当前无路由（VPN 已断/路由被删） | 先 `vpn.ps1 status` 确认连接状态 |
| 分流后局域网设备（打印机、路由器）访问不了 | 清理时把本地网段路由删多了 | 把本地网段加进 `MOTIONPRO_TARGETS` 之外的保留名单，或临时 `off` 恢复 |
| `Get-NetAdapter` 里看不到 VPN 网卡，脚本误判未连接 | MotionPro 的 SSTP 接口不出现在 `Get-NetAdapter`，只在 `Get-NetIPInterface` | 用 `Get-NetIPInterface` 按别名 `*Array Networks*` 找，并排除 `169.254.*` |
| 状态显示已连接但 `up` 一直等到超时 | 同上，检测方式用了 `Get-NetAdapter` | 同上 |
| 新建路由报 `Invalid parameter DestinationPrefix 10.0.0.0/8,172.16...` | `-Targets` 被当成一个逗号串传入 | 在脚本里对每个元素再按逗号拆分 |
| `New-NetRoute` 报参数错误 | 给 on-link 路由传了 `-NextHop 0.0.0.0` | on-link 路由不要传 NextHop，或直接用物理网关 |
| 分流后默认路由指向一个像 `192.168.31.221` 的奇怪地址 | 网关探测从邻居表取了错误的主机 | 优先取 `*.1` 且 `State=Reachable`，再用状态文件/DHCP 校验 |
| 连上 VPN 立刻断（日志 `code:5`） | 上一次的 `vpnd.exe` 带着旧会话残留 | `up` 前把 `MotionPro`、`MotionProHttpd`、`vpnd` 全部结束，再清状态 |
| 浏览器能开 tongji 站点但走的是 IPv6（没走 VPN） | 域名有 AAAA，IPv6 直连 | `-PreferIPv4`（前缀策略 60），客户端侧强制 `AF_INET` |

## 诊断顺序

1. `diagnose.ps1` —— 环境、网卡、路由、配置、代理、权限
2. `vpn.ps1 status` —— 隧道是否在
3. 日志 `%LOCALAPPDATA%\MotionPro\Log\MotionPro_<date>.log`
4. `split-vpn.ps1 status` —— 目标路由是否指向 VPN
5. 目标站点 `curl -v`，看 `remote_ip`

## 安全提醒

- 账号密码只放在用户本机的配置文件里，别写进 skill、脚本默认值或仓库。
- 很多学校禁止账号共享或多终端并发；自动化访问前确认使用条款。
- 分流的本质是把指定网段导进隧道，注意别把不该走的流量导进去。

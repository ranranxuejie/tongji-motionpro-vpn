# tongji-motionpro-vpn

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078d4)
![MotionPro](https://img.shields.io/badge/MotionPro-1.2.29-success)

用代码代替同济大学的 Array Networks **MotionPro** 图形客户端：命令行连上
`vpn.tongji.cn`，并且**只让指定的校内域名/网段走 VPN**，其余流量仍然直连。

A Windows-only agent skill + scripts that replace the Tongji University
MotionPro GUI client with a command-line connection and split-tunnel routing
(only `*.tongji.edu.cn` goes through the VPN).

- 实测环境：Windows 11 / MotionPro 1.2.29 / Windows PowerShell 5.1
- 实测结果：`www` / `study` / `my` / `agi` / `hpc` 等同济站点全部走 VPN 内网入口，
  `baidu` 等公网站点直连

```text
Default routes : 192.168.31.1 @ WLAN (metric 10)
VPN routes     : 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 202.120.0.0/16
                 (202.120.189.34/32 固定走 WLAN，避免隧道自身成环)
www.tongji.edu.cn   : 200 192.168.80.60    ← 走 VPN
agi.tongji.edu.cn   : 200 10.67.0.252      ← 走 VPN
hpc.tongji.edu.cn   : 200 192.168.216.1    ← 走 VPN
www.baidu.com       : 200 182.61.200.108   ← 直连
```

## 它解决什么

1. **不想每次手点 MotionPro**：Windows 客户端支持隐藏的命令行模式
   （`MotionPro.exe -connect <host> <port> <user> <pass> 0 0 0 1`），
   连上后客户端退出、`vpnd.exe` 在后台维持隧道。
2. **不想全局代理**：MotionPro 默认接管默认路由，所有流量走校园网。
   本仓库把它改回「物理网卡默认路由 + 指定网段走 VPN」。
3. **脚本里访问校内站点**：给出 Python 客户端，自动确保隧道已建立，
   并绕开两个常见坑（系统代理劫持、IPv6 绕过隧道）。

## 快速开始

### 1. 安装（作为 agent skill）

把本仓库目录复制到你的 skills 目录：

```powershell
git clone https://github.com/<you>/tongji-motionpro-vpn.git
Copy-Item .\tongji-motionpro-vpn "$env:USERPROFILE\.agents\skills\tongji-motionpro-vpn" -Recurse
```

也可以不装成 skill，直接跑 `scripts/` 里的脚本。

### 2. 诊断

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnose.ps1
```

检查 MotionPro 安装、已有站点配置、VPN 网卡、默认路由、管理员权限、
执行策略、系统代理。**先看报告再往下走。**

### 3. 写配置（含明文密码，别提交）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-config.ps1 `
    -Path .\motionpro.env -Host_ vpn.tongji.cn -User <学号> -Pass <密码> `
    -Targets "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,202.120.0.0/16" `
    -Dns "202.120.190.208,202.120.190.108"
```

`motionpro.env` 已在 `.gitignore` 里。

### 4. 连接 + 分流

```powershell
.\scripts\vpn.cmd up                    # 首次约 60~90 秒
.\scripts\split.cmd on -PreferIPv4      # 需要管理员，会弹 UAC
.\scripts\split.cmd status              # 只读检查
.\scripts\vpn.cmd down                  # 断开
```

> 系统禁止运行 `.ps1` 时用 `.cmd` 包装；不要为此改系统执行策略。

### 5. 在代码里用

```python
import sys
sys.path.insert(0, r"<repo>\scripts")
from motionpro_client import ensure_vpn, session

ensure_vpn()                       # 没连就自动连上
r = session().get("https://agi.tongji.edu.cn/api/v1/models", timeout=30)
print(r.status_code, r.text[:200])
```

或直接命令行：

```powershell
python .\scripts\motionpro_client.py check
python .\scripts\motionpro_client.py get https://hpc.tongji.edu.cn/
```

## 原理（三步）

1. **连接**：`MotionPro.exe -connect vpn.tongji.cn 443 <user> <pass> 0 0 0 1`，
   轮询隧道网卡拿到 IPv4 即算成功。
2. **改路由**：加回物理默认路由 → 给目标网段加 VPN 路由 → 删掉 VPN 的默认路由
   → 清掉 VPN 上多余的本地网段路由。
3. **防回抢**：置 `HKLM\SOFTWARE\VPN\VPN2\SSTPRouteMonitorOff=1`
   （只在连接时读取，所以首次要 `on -Reconnect`）。

细节见 [`references/`](references/)：

| 文档 | 内容 |
|---|---|
| [motionpro-cli.md](references/motionpro-cli.md) | 命令行参数怎么挖出来的、日志含义、版本变化时如何重新发现 |
| [split-routing.md](references/split-routing.md) | 路由被抢回的机制、完整分流顺序、隧道端点防环、IPv6 处理 |
| [troubleshooting.md](references/troubleshooting.md) | 常见报错对照表（执行策略、10053、UAC、状态残留、DTLS…） |

## 踩过的坑（都已在脚本里处理）

| 坑 | 现象 | 处理 |
|---|---|---|
| 路由被监控抢回 | 分流 4 秒后恢复全局 | 连接前置 `SSTPRouteMonitorOff=1` 并重连 |
| 隧道端点成环 | 导入 `202.120.0.0/16` 后连上即断 | 把 `vpn.tongji.cn` 的 IP 钉成 `/32` 走物理网关 |
| VPN 网卡探测错 | `Get-NetAdapter` 里只有常年 Disconnected 的 TAP 网卡 | 改用 `Get-NetIPInterface` 按别名匹配 |
| 网关探测错 | 默认路由指向 `192.168.31.221` 这类普通设备 | 优先取 `*.1` 且可达的邻居 |
| IPv6 绕过隧道 | 浏览器走 AAAA 直连 | `-PreferIPv4` 提优先级 + 客户端强制 `AF_INET` |
| 系统代理劫持 | `curl` 通、`requests` 报 `ConnectionAbortedError(10053)` | `session.trust_env = False` |
| `vpnd` 残留 | 新连接刚建立就被注销（日志 `code:5`） | `up` 前结束 `MotionPro`/`MotionProHttpd`/`vpnd` |
| `-disconnect` 挂住 | 命令不返回 | 不等它，8 秒后直接清理进程 |

## 适用范围与限制

- **仅 Windows**（依赖 MotionPro Windows 客户端与 `Get-Net*`/`netsh`）。
- 需要本机已安装 MotionPro（本仓库不提供安装包）。
- 网关若启用短信/OTP 二次认证，命令行模式会失败——那种情况只能保留 GUI，
  或改用 Linux 容器方案（见 `references/troubleshooting.md`）。
- 分流需要管理员权限；`-Elevate` 会弹 UAC。
- 每次 VPN 重连后需要再执行一次 `split-vpn.ps1 on`。
- 本仓库不含任何账号密码；`motionpro.env` 由使用者自己生成并保管。

## 合规提醒

请遵守同济大学 VPN 的使用条款：账号仅限本人使用，多数场景限制单终端在线，
不要共享账号或用于绕过访问控制。

## License

MIT

---
name: tongji-motionpro-vpn
user-invocable: true
description: "同济大学 VPN（Array Networks MotionPro）自动化：用代码代替图形客户端，命令行连上 vpn.tongji.cn，并只让指定校内域名/网段走 VPN（其余流量直连）。触发场景：用户说『用代码/MotionPro 连同济 VPN』『不用手动点 MotionPro』『只让某域名走 VPN』『校园网资源从脚本访问』『MotionPro 命令行』『同济 VPN / vpn.tongji.cn / Array Networks SSL VPN』『agi.tongji.edu.cn / hpc.tongji.edu.cn 等校内站点走 VPN』『让所有 *.tongji.edu.cn 走 VPN』。需要用户提供账号、密码，以及要走 VPN 的域名或网段。"
metadata:
  author: lead
  version: "1.1.0"
  platforms: [windows]
  scope: tongji-university
---

# 同济 VPN（MotionPro）自动化：命令行连接 + 按目标分流

把「打开 MotionPro → 双击站点 → 等连接」换成脚本，并让只有指定的校内地址走
VPN，其余流量仍然直连。全部逻辑在同济的实际环境（`vpn.tongji.cn`）上实测过：
MotionPro 1.2.29 / Windows 11。

## 同济的默认参数（可直接用，问用户确认即可）

| 项 | 值 |
|---|---|
| 网关 | `vpn.tongji.cn:443`（解析到 `202.120.189.34`） |
| 校内私网 | `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` |
| 同济公网段 | `202.120.0.0/16` |
| 校内 DNS | `202.120.190.208`、`202.120.190.108` |
| 已知内网地址 | `agi` → `10.67.0.251/252`；`hpc` → `192.168.216.1`；`www`/`study`/`my` → `192.168.80.60` |

把上面四个网段都导入 VPN，就等于「所有 `*.tongji.edu.cn` 走 VPN」——连上后校内
DNS 会把这些域名解析到上述内网地址。

## 前置条件（先跑诊断，不要假设）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/diagnose.ps1"
```

诊断会报告：MotionPro 是否安装及版本、已有配置文件、TAP 网卡、VPN 当前状态、
默认路由、管理员权限、PowerShell 执行策略、系统代理。**先看这份报告再决定下一步**：

- 没装 MotionPro → 让用户从学校/厂商页面安装，本 skill 不负责装。
- 执行策略是 `Restricted` → 一律用 `scripts/*.cmd` 包装或
  `powershell -ExecutionPolicy Bypass -File`，不要要求用户改系统设置。
- 已有配置里有网关地址 → 可以直接从 `%LOCALAPPDATA%\MotionPro\motionpro.ini`
  读出 `data\1\host`，省去问用户。
- 系统代理开着（如 `127.0.0.1:7897`）→ 记下来，Python 侧必须 `trust_env = False`。

## 需要向用户收集的信息

1. VPN 网关主机名（如 `vpn.example.edu.cn`）与端口（默认 443）
2. 账号、密码（**只写进用户本机的配置文件，绝不写进 skill 或仓库**）
3. 要走 VPN 的域名和/或网段（如 `agi.example.edu.cn`、`10.67.0.0/16`）

账号密码让用户自己填进配置文件最稳妥；也可以由用户直接告诉你，但你要写进
配置文件后立即提醒其风险。

## 步骤 1：写配置文件

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/setup-config.ps1" `
    -Path ".\motionpro.env" -Host_ "vpn.example.edu.cn" -User "学号" -Pass "密码"
```

配置是 `KEY=VALUE` 文本：

```
MOTIONPRO_HOST=vpn.example.edu.cn
MOTIONPRO_PORT=443
MOTIONPRO_USER=<学号/工号>
MOTIONPRO_PASS=<密码>
MOTIONPRO_TARGETS=agi.example.edu.cn,hpc.example.edu.cn,10.67.0.0/16
```

脚本查找配置的顺序：`-Config` 参数 → 当前目录 `motionpro.env` →
`%USERPROFILE%\.tongji-motionpro-vpn\motionpro.env` → skill 目录 `motionpro.env`。
把 `.env` 加进 `.gitignore`，并告诉用户不要提交。

## 步骤 2：连接

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/vpn.ps1" up -Config ".\motionpro.env"
```

- 首次约 60~90 秒：客户端会先做一次“web 客户端升级检查”，命令行模式下要等超时。
- 成功后 `MotionPro.exe` 退出，`vpnd.exe` 留在后台维持隧道，网卡
  `Array Networks SSL VPN` 拿到 `111.x` 或 `10.x` 地址。
- 失败时看 `%LOCALAPPDATA%\MotionPro\Log\MotionPro_<yyyy_MM_dd>.log`，里面有
  `argv[]`、`login successfully` / `Login fails`、`error = N` 等关键行。
- 断开：`vpn.ps1 down`；看状态：`vpn.ps1 status`。

## 步骤 3：分流（需要管理员）

MotionPro 连接时会把物理网卡的默认路由删掉、把 `0.0.0.0/0` 指向 VPN（全局模式）。
`split-vpn.ps1` 把它改回来：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/split-vpn.ps1" `
    on -Config ".\motionpro.env" -Elevate
```

它做四件事：

1. 把物理默认路由加回来（metric 10）；
2. 给目标网段 / 域名解析出的 `/32` 加路由走 VPN；
3. 删掉 VPN 网卡上的默认路由和其它本地网段路由（保留目标）；
4. 置 `HKLM\SOFTWARE\VPN\VPN2\SSTPRouteMonitorOff=1`，阻止 MotionPro
   的路由监控把默认路由抢回去。

第 4 步**只在连接时读取**，所以第一次建议 `on -Reconnect`（断开重连后再分流）。
每次 VPN 重连后都要再跑一次 `on`。

分流失败会**自动回滚**到全局模式并报错，不会让机器断网。

## 接管整个学校的域名（可选）

如果用户要「所有 `*.xxx.edu.cn` 都走 VPN」，不要逐个列域名，直接把目标设成
校内私网段 + 学校公网段：

```text
MOTIONPRO_TARGETS=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,202.120.0.0/16
MOTIONPRO_DNS=202.120.190.208,202.120.190.108
```

（`202.120.0.0/16` 换成该校实际公网段。）连上 VPN 后校内 DNS 会把这些域名
解析成 `10.x` / `192.168.x` / `202.120.x`，于是全部命中 VPN 路由。

三点必须注意：

1. **隧道端点要钉在物理网关上**（脚本自动做）：如果目标网段包含 VPN 服务器
   自己的地址（如 `202.120.189.34` 落在 `202.120.0.0/16` 里），不钉的话隧道
   自己的 TCP 会被导进隧道，形成环路，表现为连上就断。
2. **IPv6 会绕过隧道**：VPN 只有 IPv4，域名若有 AAAA 记录，系统会优先走 IPv6。
   用 `-PreferIPv4` 把 `::ffff:0:0/96` 的优先级提到 60，并在客户端强制 IPv4。
3. **`192.168.0.0/16` 覆盖家庭局域网**：物理网卡的 `192.168.31.0/24` on-link
   路由更具体，所以局域网设备仍可达；但如果本地网段在 `10.x` 或 `172.16-31.x`，
   要么给本地网段加更具体的路由，要么别把这些大网段整个导进 VPN。

## 步骤 4：验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/split-vpn.ps1" status -Config ".\motionpro.env"
```

必须同时满足：

- 默认路由指向物理网卡（不是 VPN）
- 目标网段/域名的路由指向 VPN
- 目标站点 HTTP 200 且 `remote_ip` 是内网地址
- 普通公网站点（如 `https://www.baidu.com/`）仍然 200

也可以直接用客户端脚本自检（同时验证 DNS、路由走向、HTTP）：

```powershell
python "${CLAUDE_SKILL_DIR}/scripts/motionpro_client.py" check
```

输出示例（网段目标会探测 `x.x.x.1` 是否走 VPN；域名目标会解析 + 请求）：

```text
[vpn] adapter ip : 111.187.80.125
[vpn] 10.0.0.0/8             probe=10.0.0.1        via_vpn=True
[vpn] 202.120.0.0/16         probe=202.120.0.1     via_vpn=True
[vpn] www.tongji.edu.cn                  dns=192.168.80.60
[vpn] https://www.tongji.edu.cn/ -> 200 (130375 bytes)
```

排查失败时看 `%LOCALAPPDATA%\tongji-motionpro-vpn\split.log`，里面按步骤记录了
物理网关、隧道端点、每条 VPN 路由和清理动作。

## 步骤 5：把访问写进用户代码

Python 侧关键三点（`scripts/motionpro_client.py` 可直接复用）：

```python
import requests

s = requests.Session()
s.trust_env = False   # 关键：忽略系统代理，否则 192.168./10. 目标会被代理重置
r = s.get("https://agi.example.edu.cn/", timeout=20)
```

- **必须 `trust_env = False`**：Windows 上开着 Clash 之类的系统代理时，
  `requests` 会把内网请求交给代理，报 `ConnectionAbortedError(10053)`，
  而 `curl` 不读系统代理所以看起来“curl 能通、Python 不通”。
- 域名解析要走校内 DNS 才能拿到内网地址；分流脚本已把校内 DNS 的 `/32`
  指到 VPN，所以直接用系统解析即可。
- 需要的话用 `ensure_vpn()` 在请求前确保隧道已建立。

## 不要做的事

- 不要把账号密码写进 skill 文件、脚本默认值、README 或提交记录。
- 不要在没有管理员权限时反复尝试改路由：会静默失败或半途而废，先 `-Elevate`。
- 不要在 VPN 已连接时直接 `route delete` 全部路由：会断网。用脚本的回滚路径。
- 不要假设网关支持开源客户端：Array AG 的 `openconnect --protocol=array`
  只支持用户名密码，有短信/OTP 二次认证的网关必须走 MotionPro 本体。

## 参考

| 文件 | 内容 |
|---|---|
| `references/motionpro-cli.md` | MotionPro 命令行参数是怎么挖出来的、日志含义、版本差异时如何重新发现 |
| `references/split-routing.md` | 路由监控注册表、为什么会被抢回默认路由、完整的分流顺序 |
| `references/troubleshooting.md` | 执行策略、系统代理、UAC、二次认证、DTLS、常见报错对照表 |

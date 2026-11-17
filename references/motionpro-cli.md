# MotionPro 命令行：参数、日志与重新发现方法

## 结论

Windows 版 MotionPro 支持命令行连接（官方文档只写了 Linux 的 `vpn_cmdline`，
但 Windows 二进制里带着完整用法）：

```text
MotionPro.exe [ConnectMode] [Host] [Port] [Username] [Password] \
              [ReconnectTime] [ReconnectCount] [AuthenticationType] [TunnelType] \
              [Proxyhost] [Proxyuser] [Proxypassword]

MotionPro.exe -connect intranet.vpn.com 443 test test 0 0 0 1
MotionPro.exe -disconnect
```

- `ConnectMode`：`-connect`（无界面）或 `-connectwithui`（带界面）
- `TunnelType`：`0` 自动探测，`1` L3 资源，`2` DD 与 L4 资源
- `ReconnectTime` / `ReconnectCount` / `AuthenticationType` 一般填 `0`
- 实测（MotionPro 1.2.29 / Windows 11）：`-connect <host> 443 <user> <pass> 0 0 0 1`

## 连接过程

1. `MotionPro.exe` 解析 argv，登录（`POST /prx/000/http/localhost/login`），
   拿到 `ANsession` cookie；
2. 拉起/复用 `vpnd.exe` 建立 SSTP/DTLS 隧道，配置 TAP 网卡与路由；
3. 连接成功后 `MotionPro.exe` 退出，`vpnd.exe` 常驻维持隧道。

所以判断“是否已连接”不要看 `MotionPro.exe` 进程，要看：

- TAP 网卡（描述含 `Array Networks`）是否有 IPv4 地址；
- 路由表里是否有指向该网卡的默认路由（全局模式）；
- `vpnd.exe` 是否在跑。

## 首次连接慢 60~90 秒

连接前客户端会做一次“web MotionPro 客户端升级检查”
（日志：`IsContinueUpgrade: web MotionPro client, continue upgrade client.`），
命令行模式下没有界面可以点“跳过”，只能等它超时。
`HKLM\...\VPN2\disableautoupdate=1` 只关提示，不影响这段等待。

## 日志

`%LOCALAPPDATA%\MotionPro\Log\MotionPro_<yyyy_MM_dd>.log`

关键行：

| 日志片段 | 含义 |
|---|---|
| `MotionPro(main) start, argc=N` / `argv[i]=...` | 参数解析（密码只显示 `proxypassword=***`） |
| `login successfully, method name:` | 登录成功 |
| `Login fails. Please check your username and password.` | 账号或密码错 |
| `get_user_apps: ..._uname=<账号>` | 实际使用的账号，可核对 |
| `GetVPNStatusFromReg: ... status=N` | 注册表里的状态（`0` 空闲） |
| `VPN status is connecting or connected, no need connect repeatable.` | 状态残留导致 CLI 直接退出 |
| `This is DD only mode` | 隧道类型判定 |
| `wait_status_finished ... recv the real status: 2` | 网卡配置完成（`2` = connected） |

## 状态残留

状态写在 `HKCU\Software\VPN\VPN2`：

- `VPNstatus`、`status`、`MPCommandLineFlag`

被强杀（`taskkill /F`）后这些值可能停在“已连接”，下次 `-connect` 会直接
“无需重复连接”然后退出。脚本在 `up` 前会把它们清 0。

## `-disconnect` 可能挂住

`Start-Process -Wait` 等 `-disconnect` 有概率长时间不返回。稳妥做法是：

```powershell
Start-Process $mp -ArgumentList '-disconnect' | Out-Null
Start-Sleep -Seconds 8
Get-Process MotionPro, MotionProHttpd, vpnd | Stop-Process -Force
```

## 版本变化时如何重新发现参数

客户端升级后参数可能变。用字符串提取找用法（无需反编译）：

```powershell
python -c "import re;d=open(r'C:\Program Files\Array Networks\MotionPro VPN Client\MotionPro.exe','rb').read();
[print(repr(s.decode('latin1'))) for s in re.findall(rb'[\x20-\x7e]{20,400}', d) if b'ConnectMode' in s]"
```

或搜索 `MotionPro.exe [`、`-connectwithui`、`-disconnect`、`argv`。

## 已知限制

- Windows 客户端没有 Linux 那种 `-h/-u/-p` 短选项，只有上面的位置参数。
- 二次认证（短信/OTP）在 GUI 里弹框输入；命令行模式遇到会失败或挂起，
  这种情况要么保留 GUI，要么改用容器方案。
- 同一时间只应存在一个客户端实例。

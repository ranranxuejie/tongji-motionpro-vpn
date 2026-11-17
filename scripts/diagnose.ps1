# 只读诊断：报告环境是否具备“命令行连 MotionPro + 按目标分流”的条件。
# 不需要管理员权限，不改任何配置。
[CmdletBinding()]
param([string]$Config = '')

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')

"===== 系统 ====="
"OS            : $((Get-CimInstance Win32_OperatingSystem).Caption)"
"PowerShell    : $($PSVersionTable.PSVersion)"
"管理员        : $(Test-Admin)"
"执行策略      : $(Get-ExecutionPolicy)"
"当前目录      : $((Get-Location).Path)"

"`n===== MotionPro ====="
$exe = Find-MpExe
if ($exe) {
    "安装路径      : $exe"
    "版本          : $((Get-Item $exe).VersionInfo.FileVersion)"
} else {
    "安装路径      : (未找到) —— 需要先安装 MotionPro 客户端"
}
"vpnd 进程     : $([bool](Get-Process vpnd -ErrorAction SilentlyContinue))"
"服务          : $((Get-Service | Where-Object { $_.Name -match 'VPNService|VPNInstallManager' } | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')"

"`n===== 已有配置（可从中读出网关地址） ====="
$ini = Join-Path $env:LOCALAPPDATA 'MotionPro\motionpro.ini'
if (Test-Path $ini) {
    Select-String -Path $ini -Pattern '^(default_profile|data\\\d+\\name|data\\\d+\\host|data\\\d+\\port|data\\\d+\\username)=' |
        ForEach-Object { "  " + $_.Line }
} else {
    "  (没有 motionpro.ini，说明客户端从未配置过站点)"
}

"`n===== 网卡与路由 ====="
Get-NetAdapter | Where-Object { $_.InterfaceDescription -like $script:VpnDescLike -or $_.Status -eq 'Up' } |
    Select-Object Name, InterfaceDescription, Status, ifIndex |
    Format-Table -AutoSize | Out-String
$vpn = Get-VpnInfo
if ($vpn) {
    "VPN 网卡      : $($vpn.Alias) if=$($vpn.IfIndex) ip=$($vpn.Ip) gw=$($vpn.Gw)"
} else {
    "VPN 网卡      : (未出现，VPN 未连接)"
}
"默认路由："
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Select-Object NextHop, InterfaceIndex, InterfaceAlias, RouteMetric |
    Format-Table -AutoSize | Out-String

"`n===== 分流开关 ====="
foreach ($k in 'HKLM:\SOFTWARE\VPN\VPN2', 'HKLM:\SOFTWARE\WOW6432Node\VPN\VPN2') {
    if (Test-Path $k) {
        "  $k SSTPRouteMonitorOff = $((Get-ItemProperty $k -Name SSTPRouteMonitorOff -ErrorAction SilentlyContinue).SSTPRouteMonitorOff)"
    }
}

"`n===== 配置文件 ====="
$path = Resolve-ConfigPath $Config
if ($path) {
    $cfg = Read-Config $path
    "路径          : $path"
    "网关          : $($cfg['MOTIONPRO_HOST']) : $($cfg['MOTIONPRO_PORT'])"
    "账号          : $($cfg['MOTIONPRO_USER'])"
    "密码          : $(if ($cfg['MOTIONPRO_PASS']) { '(已设置)' } else { '(未设置)' })"
    "目标          : $($cfg['MOTIONPRO_TARGETS'])"
    "校内 DNS      : $($cfg['MOTIONPRO_DNS'])"
} else {
    "路径          : (未找到 motionpro.env)"
}

"`n===== 系统代理（会影响 Python requests） ====="
$reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
"ProxyEnable   : $($reg.ProxyEnable)"
"ProxyServer   : $($reg.ProxyServer)"
"ProxyOverride : $($reg.ProxyOverride)"
if ($reg.ProxyEnable -eq 1) {
    "提示          : 系统代理已开启，Python 里必须 requests.Session().trust_env = False"
}

"`n===== 结论 ====="
$ready = ($exe -and (Test-Admin))
"可以连接      : $([bool]$exe)"
"可以改路由    : $(Test-Admin)  (分流需要管理员；连接不需要)"
"下一步        : $(if (-not $exe) { '安装 MotionPro' } elseif (-not (Test-Path (Join-Path $env:USERPROFILE '.tongji-motionpro-vpn\motionpro.env'))) { '写配置：setup-config.ps1' } else { 'vpn.ps1 up' })"

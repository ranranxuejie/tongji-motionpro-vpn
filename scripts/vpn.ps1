# 连接 / 断开 / 查看 MotionPro VPN（命令行模式，不弹 GUI）。
#
#   vpn.ps1 status [-Config .\motionpro.env]
#   vpn.ps1 up     [-Config .\motionpro.env] [-TimeoutSec 180]
#   vpn.ps1 down   [-Config .\motionpro.env]
#
# 凭据来源（优先级从高到低）：
#   1) 参数 -User / -Pass / -Host_ / -Port
#   2) 环境变量 MOTIONPRO_USER / MOTIONPRO_PASS / MOTIONPRO_HOST / MOTIONPRO_PORT
#   3) 配置文件（KEY=VALUE）：同目录 motionpro.env、%USERPROFILE%\.tongji-motionpro-vpn\motionpro.env
[CmdletBinding()]
param(
    [ValidateSet('status', 'up', 'down')]
    [string]$Action = 'status',
    [string]$Config = '',
    [string]$Host_ = '',
    [int]$Port = 0,
    [string]$User = '',
    [string]$Pass = '',
    [int]$TimeoutSec = 180,
    [string]$MpExe = ''
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-Settings {
    $path = Resolve-ConfigPath $Config
    $cfg = Read-Config $path
    $h = if ($Host_) { $Host_ } else { Get-Cfg $cfg 'MOTIONPRO_HOST' '' }
    $p = if ($Port) { $Port } else { [int](Get-Cfg $cfg 'MOTIONPRO_PORT' '443') }
    $u = if ($User) { $User } else { Get-Cfg $cfg 'MOTIONPRO_USER' '' }
    $w = if ($Pass) { $Pass } else { Get-Cfg $cfg 'MOTIONPRO_PASS' '' }
    [pscustomobject]@{ Path = $path; Host = $h; Port = $p; User = $u; Pass = $w }
}

function Show-Status {
    $vpn = Get-VpnInfo
    $exeNow = if ($MpExe) { $MpExe } else { Find-MpExe }
    $alias = if ($vpn) { $vpn.Alias } else { '(not present)' }
    $ip    = if ($vpn) { $vpn.Ip } else { '' }
    $gw    = if ($vpn) { $vpn.Gw } else { '' }
    $def   = if ($vpn) { $vpn.HasDefault } else { $false }
    "MotionPro    : $exeNow"
    "VPN adapter  : $alias"
    "VPN IPv4     : $ip"
    "VPN gateway  : $gw"
    "VPN default  : $def"
    "vpnd running : $([bool](Get-Process vpnd -ErrorAction SilentlyContinue))"
}

function Wait-Vpn([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $vpn = Get-VpnInfo
        if ($vpn -and $vpn.Ip) { return $vpn }
        Start-Sleep -Seconds 3
    }
    return $null
}

$settings = Get-Settings
$exe = if ($MpExe) { $MpExe } else { Find-MpExe }

switch ($Action) {
    'status' {
        Show-Status
        $vpn = Get-VpnInfo
        if ($vpn -and $vpn.Ip) { exit 0 } else { exit 1 }
    }

    'up' {
        $vpn = Get-VpnInfo
        if ($vpn -and $vpn.Ip) {
            "[vpn] already connected: $($vpn.Ip)"
            exit 0
        }
        if (-not $exe) { "[vpn] 找不到 MotionPro.exe，请先安装客户端" | Write-Error; exit 3 }
        if (-not $settings.Host -or -not $settings.User -or -not $settings.Pass) {
            "[vpn] 缺少网关/账号/密码。用 -Config 指定配置文件，或设置 MOTIONPRO_HOST/USER/PASS" | Write-Error
            exit 2
        }

        Clear-StaleStatus
        # 上一次会话残留的 vpnd 会带着旧状态，让新连接刚建立就被注销（日志 code:5）
        Get-Process MotionPro, MotionProHttpd, vpnd -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() }
        Start-Sleep -Seconds 3

        "[vpn] connecting $($settings.Host):$($settings.Port) as $($settings.User) ..."
        $argv = @('-connect', $settings.Host, "$($settings.Port)", $settings.User, $settings.Pass, '0', '0', '0', '1')
        Start-Process -FilePath $exe -ArgumentList $argv | Out-Null

        $result = Wait-Vpn $TimeoutSec
        if (-not $result) {
            $log = Join-Path $env:LOCALAPPDATA ("MotionPro\Log\MotionPro_{0}.log" -f (Get-Date -Format 'yyyy_MM_dd'))
            "[vpn] ${TimeoutSec}s 内未连上；日志: $log" | Write-Error
            exit 4
        }
        "[vpn] connected: $($result.Ip)  gw=$($result.Gw)"
        exit 0
    }

    'down' {
        if ($exe) {
            Start-Process -FilePath $exe -ArgumentList '-disconnect' | Out-Null
            Start-Sleep -Seconds 8
        }
        Get-Process MotionPro, MotionProHttpd, vpnd -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Kill() }
        Start-Sleep -Seconds 2
        Clear-StaleStatus
        $vpn = Get-VpnInfo
        if ($vpn -and $vpn.Ip) { "[vpn] 仍处于连接状态（$($vpn.Ip)），请在客户端里断开" | Write-Warning; exit 1 }
        "[vpn] disconnected"
        exit 0
    }
}

# 只让指定域名/网段走 VPN，其余流量走本地网络。需要管理员权限。
#
#   split-vpn.ps1 status [-Config .\motionpro.env]
#   split-vpn.ps1 on  [-Config .\motionpro.env] [-Reconnect] [-Elevate] [-PreferIPv4]
#   split-vpn.ps1 off [-Config .\motionpro.env] [-Elevate]
#
# 目标来自 MOTIONPRO_TARGETS（逗号分隔，含 / 的当网段，否则当域名），
# 也可用 -Targets 覆盖。要把整个学校域名接管，就填校内私网段 + 学校公网段。
[CmdletBinding()]
param(
    [ValidateSet('status', 'on', 'off')]
    [string]$Action = 'status',
    [string]$Config = '',
    [string[]]$Targets = @(),
    [string[]]$DnsServers = @(),
    [switch]$Reconnect,
    [switch]$Elevate,
    [switch]$PreferIPv4,
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')

$VpnScript = Join-Path $PSScriptRoot 'vpn.ps1'
$LogFile = Join-Path $env:LOCALAPPDATA 'tongji-motionpro-vpn\split.log'

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
    Write-Output $line
}

function Get-Targets {
    if ($Targets.Count -gt 0) {
        return @($Targets | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    }
    $cfg = Read-Config (Resolve-ConfigPath $Config)
    $raw = Get-Cfg $cfg 'MOTIONPRO_TARGETS' ''
    if (-not $raw) {
        $state = Load-State
        if ($state -and $state.targets) { return @($state.targets) }
        return @()
    }
    return @($raw -split '[,;\s]+' | Where-Object { $_ })
}

function Get-DnsList($targets) {
    if ($DnsServers.Count -gt 0) { return $DnsServers }
    $cfg = Read-Config (Resolve-ConfigPath $Config)
    $raw = Get-Cfg $cfg 'MOTIONPRO_DNS' ''
    if ($raw) { return @($raw -split '[,;\s]+' | Where-Object { $_ }) }
    $vpn = Get-VpnInfo
    if ($vpn) {
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $vpn.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        return @($dns | Where-Object { $_ -and $_ -ne '127.0.0.1' })
    }
    return @()
}

function Test-GatewayReachable([string]$Gw) {
    if (-not $Gw) { return $false }
    $n = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -eq $Gw -and $_.State -ne 'Unreachable' }
    if ($n) { return $true }
    return (Test-Connection -ComputerName $Gw -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

function Resolve-PhysGateway {
    # 1) 现存的非 VPN 默认路由（若指向的不是 *.1，优先找同网段可达的 *.1，
    #    防止沿用之前写错的网关）
    $r = Get-PhysicalDefault
    if ($r) {
        if ($r.NextHop -notlike '*.1') {
            $alt = Get-NetNeighbor -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -like '*.1' -and $_.State -eq 'Reachable' } |
                   Select-Object -First 1
            if ($alt) {
                return [pscustomobject]@{ IfIndex = $r.InterfaceIndex; Gw = $alt.IPAddress; Source = 'neighbor-.1' }
            }
        }
        return [pscustomobject]@{ IfIndex = $r.InterfaceIndex; Gw = $r.NextHop; Source = 'default-route' }
    }

    # 2) 上次缓存，但要验证可达，避免沿用错误网关
    $st = Load-State
    if ($st -and $st.physIf -and $st.physGw -and (Test-GatewayReachable $st.physGw)) {
        return [pscustomobject]@{ IfIndex = [int]$st.physIf; Gw = $st.physGw; Source = 'state' }
    }

    # 3) 从物理网卡的邻居表里找网关（优先 *.1，且必须可达）
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.IPv4Address -and $_.InterfaceAlias -notmatch 'Array|Loopback'
    } | Select-Object -First 1
    if (-not $cfg) { return $null }
    $neigh = Get-NetNeighbor -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.State -in @('Reachable', 'Stale', 'Permanent') -and $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' }
    $cand = ($neigh | Where-Object { $_.IPAddress -like '*.1' } | Select-Object -First 1).IPAddress
    if (-not $cand) { $cand = ($neigh | Sort-Object { [version]$_.IPAddress } | Select-Object -First 1).IPAddress }
    if (-not $cand) { return $null }
    return [pscustomobject]@{ IfIndex = $cfg.InterfaceIndex; Gw = $cand; Source = 'neighbor' }
}

function Test-Split($resolved) {
    $vpn = Get-VpnInfo
    if (-not $vpn -or -not $vpn.Ip) { return $false }
    $vpnDefault = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                  Where-Object InterfaceIndex -eq $vpn.IfIndex
    if ($vpnDefault) { return $false }
    $phys = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object InterfaceIndex -ne $vpn.IfIndex
    if (-not $phys) { return $false }
    $checked = 0
    foreach ($prefix in $resolved.Subnets) {
        $probe = ConvertTo-ProbeIp $prefix
        if (-not $probe) { continue }
        $checked++
        $r = Find-NetRoute -RemoteIPAddress $probe -ErrorAction SilentlyContinue |
             Where-Object { $_.InterfaceIndex -eq $vpn.IfIndex }
        if (-not $r) { return $false }
    }
    foreach ($ip in $resolved.Ips) {
        $checked++
        $r = Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue |
             Where-Object { $_.InterfaceIndex -eq $vpn.IfIndex }
        if (-not $r) { return $false }
    }
    if ($checked -eq 0) { return $false }
    return $true
}

function Set-IPv4Preference([bool]$Enable) {
    # VPN 只有 IPv4；若目标域名同时有 AAAA 记录，流量会走 IPv6 绕过隧道。
    # 提高 ::ffff:0:0/96（IPv4 映射）优先级，让解析结果优先用 A 记录。
    # 需要管理员权限。
    $prec = if ($Enable) { '60' } else { '35' }
    & netsh interface ipv6 set prefixpolicy '::ffff:0:0/96' $prec 4 2>&1 | Out-Null
    ipconfig /flushdns 2>&1 | Out-Null
}

function Split-On($resolved) {
    $vpn = Get-VpnInfo
    if (-not $vpn -or -not $vpn.Ip) { throw 'VPN 未连接，先运行 vpn.ps1 up' }

    $phys = Resolve-PhysGateway
    if (-not $phys) { throw '找不到物理网卡/网关，无法恢复默认路由' }
    $physIf = $phys.IfIndex
    $physGw = $phys.Gw
    Write-Log "[split] 物理网关: $physIf/$physGw (来源: $($phys.Source))"

    $vpnGw = $vpn.Gw
    if (-not $vpnGw) {
        $st = Load-State
        if ($st -and $st.vpnGw) { $vpnGw = $st.vpnGw }
    }
    if (-not $vpnGw) { throw '拿不到 VPN 网关地址（VPN 未完全连接？）' }

    $keep = @($resolved.Subnets)
    foreach ($ip in $resolved.Ips) { $keep += "$ip/32" }

    Save-State @{
        vpnIf   = $vpn.IfIndex
        vpnGw   = $vpnGw
        physIf  = $physIf
        physGw  = $physGw
        targets = $resolved.Targets
    } | Out-Null

    # 1) 清掉物理网卡上错误的默认路由，再把正确的加回来
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceIndex -eq $physIf -and $_.NextHop -ne $physGw } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Add-RouteIfMissing '0.0.0.0/0' $physIf $physGw 10
    Write-Log "[split] 物理默认路由: 0.0.0.0/0 -> $physGw@$physIf"

    # 2) 钉住隧道端点，避免目标网段包含 VPN 服务器地址时形成环路
    $cfgFile = Read-Config (Resolve-ConfigPath $Config)
    $vpnHost = Get-Cfg $cfgFile 'MOTIONPRO_HOST' ''
    if ($vpnHost) {
        $hostIps = Resolve-DnsName $vpnHost -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
        foreach ($hip in $hostIps) {
            try {
                # 清掉之前指向错误网关的同名 /32 路由
                Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "$hip/32" -ErrorAction SilentlyContinue |
                    Where-Object { $_.NextHop -ne $physGw } |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                Add-RouteIfMissing "$hip/32" $physIf $physGw 1
                Write-Log "[split] 隧道端点 $hip -> 物理网关"
            } catch { Write-Log "[split] 钉端点失败 $hip : $($_.Exception.Message)" }
        }
    }

    # 3) 目标走 VPN
    foreach ($prefix in $keep) {
        try {
            Add-RouteIfMissing $prefix $vpn.IfIndex $vpnGw 1
            Write-Log "[split] VPN 路由: $prefix -> $vpnGw@$($vpn.IfIndex)"
        } catch { Write-Log "[split] 加路由失败 $prefix : $($_.Exception.Message)" }
    }

    # 4) 删掉 VPN 的默认路由
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object InterfaceIndex -eq $vpn.IfIndex |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "[split] 已删除 VPN 默认路由"

    # 5) 删掉 VPN 上残留的本地网段路由（保留目标）
    Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceIndex -eq $vpn.IfIndex -and
            $_.DestinationPrefix -match '^(192\.168\.|10\.245\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and
            $keep -notcontains $_.DestinationPrefix
        } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "[split] 已清理 VPN 上多余本地网段路由"

    # 6) 关掉 MotionPro 路由监控，供下次连接使用
    Set-RouteMonitor 1
    if ($PreferIPv4) { Set-IPv4Preference $true; Write-Log "[split] 已设置 IPv4 优先" }
}

function Split-Off($resolved) {
    $vpn = Get-VpnInfo
    if (-not $vpn) { throw 'VPN 未连接' }
    $st = Load-State
    $vpnGw = if ($vpn.Gw) { $vpn.Gw } elseif ($st) { $st.vpnGw } else { $null }

    Set-RouteMonitor 0
    foreach ($prefix in $resolved.Subnets) {
        Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -eq $vpn.IfIndex -and $_.DestinationPrefix -eq $prefix } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($vpnGw) { Add-RouteIfMissing '0.0.0.0/0' $vpn.IfIndex $vpnGw 0 }
    Set-IPv4Preference $false
}

function Show-Status($resolved) {
    $vpn = Get-VpnInfo
    "VPN connected : $([bool]($vpn -and $vpn.Ip))"
    if ($vpn) { "VPN if/ip/gw  : $($vpn.IfIndex) / $($vpn.Ip) / $($vpn.Gw)" }
    "Targets       : $($resolved.Targets -join ', ')"
    "Default routes:"
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Select-Object NextHop, InterfaceIndex, InterfaceAlias, RouteMetric |
        Format-Table -AutoSize | Out-String
    "VPN routes    :"
    Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $vpn -and $_.InterfaceIndex -eq $vpn.IfIndex -and $_.DestinationPrefix -ne '255.255.255.255/32' } |
        Select-Object DestinationPrefix, NextHop |
        Format-Table -AutoSize | Out-String
    if ($vpn) { "split active  : $(Test-Split $resolved)" }
}

# ---------------- main ----------------
$targets = Get-Targets
$dns = Get-DnsList $targets
$resolved = Resolve-Targets $targets $dns
$resolved | Add-Member -NotePropertyName Targets -NotePropertyValue $targets -Force

if ($Action -ne 'off') {
    foreach ($s in $resolved.Subnets) { "[split] 网段: $s" }
    foreach ($ip in $resolved.Ips) { "[split] 域名解析: $ip" }
}

if ($Action -eq 'status') {
    Show-Status $resolved
    exit 0
}

if (-not (Test-Admin)) {
    if ($Elevate) {
        $splat = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Action)
        if ($Config) { $splat += @('-Config', $Config) }
        if ($Reconnect) { $splat += '-Reconnect' }
        if ($PreferIPv4) { $splat += '-PreferIPv4' }
        if ($targets.Count -gt 0) { $splat += @('-Targets', ($targets -join ',')) }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $splat | Out-Null
        "[split] 已请求管理员权限，请在 UAC 弹窗中确认"
        exit 0
    }
    "[split] 需要管理员权限：以管理员身份运行，或加 -Elevate" | Write-Error
    exit 5
}

try {
    if ($Action -eq 'on') {
        if ($targets.Count -eq 0) { "[split] 没有目标，先设置 MOTIONPRO_TARGETS 或用 -Targets" | Write-Error; exit 8 }
        if ($Reconnect) {
            Write-Log '[split] 重连：先关路由监控再重连'
            Set-RouteMonitor 1
            & powershell -NoProfile -ExecutionPolicy Bypass -File $VpnScript down -Config $Config | Out-Null
            Start-Sleep -Seconds 2
            & powershell -NoProfile -ExecutionPolicy Bypass -File $VpnScript up -Config $Config | Out-Null
            $resolved = Resolve-Targets $targets $dns
            $resolved | Add-Member -NotePropertyName Targets -NotePropertyValue $targets -Force
        } elseif (-not (Get-VpnInfo)) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $VpnScript up -Config $Config | Out-Null
        }
        Split-On $resolved
        Start-Sleep -Seconds 6
        if (-not (Test-Split $resolved)) {
            Write-Log '[split] 首次校验未通过，再修一次'
            Split-On $resolved
        }
        Start-Sleep -Seconds 4
        Show-Status $resolved
        if (Test-Split $resolved) { Write-Log '[split] OK：只有目标走 VPN'; exit 0 }
        Write-Log '[split] 分流未生效，回滚为全局模式'
        Split-Off $resolved
        exit 6
    }
    if ($Action -eq 'off') {
        Split-Off $resolved
        Show-Status $resolved
        "[split] 已恢复全局模式"
        exit 0
    }
} catch {
    Write-Log "[split] 失败: $($_.Exception.Message)"
    exit 7
}

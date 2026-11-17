# 公共函数：被 vpn.ps1 / split-vpn.ps1 / diagnose.ps1 点源引用。
# 不要单独运行。

$script:SkillRoot   = $PSScriptRoot
$script:StateDir    = Join-Path $env:LOCALAPPDATA 'tongji-motionpro-vpn'
$script:StateFile   = Join-Path $script:StateDir 'state.json'
$script:VpnDescLike = 'Array Networks*'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-MpExe {
    $candidates = @(
        'C:\Program Files\Array Networks\MotionPro VPN Client\MotionPro.exe',
        'C:\Program Files (x86)\Array Networks\MotionPro VPN Client\MotionPro.exe'
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $hit = Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Directory -ErrorAction SilentlyContinue |
           Where-Object Name -match 'Array Networks' |
           ForEach-Object { Join-Path $_.FullName 'MotionPro VPN Client\MotionPro.exe' } |
           Where-Object { Test-Path $_ } | Select-Object -First 1
    return $hit
}

function Resolve-ConfigPath([string]$Config) {
    if ($Config) {
        if (Test-Path $Config) { return (Resolve-Path $Config).Path }
        return $null
    }
    $candidates = @(
        (Join-Path (Get-Location).Path 'motionpro.env'),
        (Join-Path $env:USERPROFILE '.tongji-motionpro-vpn\motionpro.env'),
        (Join-Path $script:SkillRoot 'motionpro.env')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Read-Config([string]$Path) {
    $cfg = @{}
    if (-not $Path -or -not (Test-Path $Path)) { return $cfg }
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $v = $matches[2]
            if ($v -match '^"(.*)"$') { $v = $matches[1] }
            $cfg[$matches[1]] = $v
        }
    }
    return $cfg
}

function Get-Cfg([hashtable]$Cfg, [string]$Name, [string]$Default = '') {
    $fromEnv = [Environment]::GetEnvironmentVariable($Name)
    if ($fromEnv) { return $fromEnv }
    if ($Cfg.ContainsKey($Name) -and $Cfg[$Name]) { return $Cfg[$Name] }
    return $Default
}

function Save-State($obj) {
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Load-State {
    if (Test-Path $script:StateFile) {
        return (Get-Content $script:StateFile -Raw | ConvertFrom-Json)
    }
    return $null
}

function Get-VpnInfo {
    # 注意：MotionPro 的隧道接口（SSTP）不一定出现在 Get-NetAdapter 里，
    # 但一定出现在 Get-NetIPInterface 里，别用 Get-NetAdapter 判断。
    $ifaces = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.InterfaceAlias -like '*Array Networks*' }
    foreach ($iface in $ifaces) {
        $ip = (Get-NetIPAddress -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Select-Object -First 1).IPAddress
        if (-not $ip -or $ip -like '169.254.*') { continue }
        $def = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Where-Object InterfaceIndex -eq $iface.InterfaceIndex | Select-Object -First 1
        $state = Load-State
        $gw = if ($def) { $def.NextHop } elseif ($state -and $state.vpnGw) { $state.vpnGw } else { $null }
        return [pscustomobject]@{
            IfIndex    = $iface.InterfaceIndex
            Alias      = $iface.InterfaceAlias
            Ip         = $ip
            Gw         = $gw
            HasDefault = [bool]$def
        }
    }
    return $null
}

function Clear-StaleStatus {
    $key = 'HKCU:\Software\VPN\VPN2'
    if (Test-Path $key) {
        foreach ($n in 'VPNstatus', 'status', 'MPCommandLineFlag') {
            Set-ItemProperty $key -Name $n -Value 0 -ErrorAction SilentlyContinue
        }
    }
}

function Set-RouteMonitor([int]$Value) {
    foreach ($key in @('HKLM:\SOFTWARE\VPN\VPN2', 'HKLM:\SOFTWARE\WOW6432Node\VPN\VPN2')) {
        if (Test-Path $key) {
            Set-ItemProperty -Path $key -Name SSTPRouteMonitorOff -Value $Value -Type DWord -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-ProbeIp([string]$Prefix) {
    # '10.67.0.0/16' -> '10.67.0.1'；'/32' 原样返回
    $parts = $Prefix.Split('/')
    if ($parts.Count -ne 2) { return $null }
    $ip = $parts[0]
    $len = [int]$parts[1]
    if ($len -ge 32) { return $ip }
    $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    $bytes[3] = $bytes[3] + 1
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Resolve-Targets([string[]]$Targets, [string[]]$DnsServers) {
    # 返回 @{ Subnets=@(); Ips=@() }；域名用给定 DNS（缺省用系统）解析
    $subnets = @()
    $ips = @()
    foreach ($t in $Targets) {
        $t = $t.Trim()
        if (-not $t) { continue }
        if ($t -match '/') { $subnets += $t; continue }
        $answer = $null
        foreach ($dns in $DnsServers) {
            $answer = Resolve-DnsName $t -Server $dns -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue |
                      Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
            if ($answer) { break }
        }
        if (-not $answer) {
            $answer = Resolve-DnsName $t -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue |
                      Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
        }
        if ($answer) { $ips += $answer } else { Write-Warning "[vpn] 域名解析失败，跳过: $t" }
    }
    [pscustomobject]@{
        Subnets = ($subnets | Sort-Object -Unique)
        Ips     = ($ips | Sort-Object -Unique)
    }
}

function Add-RouteIfMissing($Prefix, $IfIndex, $NextHop, $Metric) {
    $existing = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $Prefix -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceIndex -eq $IfIndex -and $_.NextHop -eq $NextHop }
    if (-not $existing) {
        New-NetRoute -DestinationPrefix $Prefix -InterfaceIndex $IfIndex -NextHop $NextHop `
                     -RouteMetric $Metric -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    }
}

function Get-PhysicalDefault {
    $vpn = Get-VpnInfo
    $candidates = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                  Where-Object { -not $vpn -or $_.InterfaceIndex -ne $vpn.IfIndex }
    if ($candidates) { return $candidates | Sort-Object RouteMetric | Select-Object -First 1 }
    return $null
}

function Find-PhysicalGateway {
    $state = Load-State
    if ($state -and $state.physIf -and $state.physGw) {
        return [pscustomobject]@{ IfIndex = [int]$state.physIf; Gw = $state.physGw }
    }
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.IPv4Address -and $_.InterfaceAlias -notmatch 'Array|Loopback'
    } | Select-Object -First 1
    if (-not $cfg) { return $null }
    $neigh = Get-NetNeighbor -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.State -in @('Reachable', 'Stale', 'Permanent') -and $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' }
    $gw = ($neigh | Where-Object { $_.IPAddress -like '*.1' } | Select-Object -First 1).IPAddress
    if (-not $gw) { $gw = ($neigh | Sort-Object { [version]$_.IPAddress } | Select-Object -First 1).IPAddress }
    if (-not $gw) { return $null }
    [pscustomobject]@{ IfIndex = $cfg.InterfaceIndex; Gw = $gw }
}

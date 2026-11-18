# 同济 VPN 控制台（图形界面启动器）
#
# 双击「启动器.cmd」打开。界面只负责交互与状态显示，
# 实际动作调用同目录（或 scripts/）下的 vpn.ps1 / split-vpn.ps1。
#
# 所有输出同时写入 %LOCALAPPDATA%\tongji-motionpro-vpn\launcher.log，便于排查。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'SilentlyContinue'

# ---------- 路径 ----------
# 启动器可能通过两种方式运行：
#   1) 启动器.cmd 用 [scriptblock]::Create 加载（这时没有脚本路径，靠 TONGJI_VPN_DIR）
#   2) 直接 powershell -File launcher.ps1（这时用脚本所在目录）
$Root = $env:TONGJI_VPN_DIR
if (-not $Root) {
    if ($MyInvocation.MyCommand.Path) {
        $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $Root = (Get-Location).Path
    }
}
$Root = $Root.TrimEnd('\')
$DataDir = Join-Path $env:LOCALAPPDATA 'tongji-motionpro-vpn'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
$LauncherLog = Join-Path $DataDir 'launcher.log'

function Find-Engine([string]$Name) {
    $cands = @(
        (Join-Path $Root $Name),
        (Join-Path $Root "scripts\$Name"),
        (Join-Path (Split-Path -Parent $Root) "scripts\$Name"),
        (Join-Path (Split-Path -Parent $Root) $Name)
    )
    foreach ($c in $cands) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    return $null
}
$VpnScript   = Find-Engine 'vpn.ps1'
$SplitScript = Find-Engine 'split-vpn.ps1'

function Find-Config {
    $cands = @(
        (Join-Path $Root 'motionpro.env'),
        (Join-Path (Split-Path -Parent $Root) 'motionpro.env'),
        (Join-Path $env:USERPROFILE '.tongji-motionpro-vpn\motionpro.env')
    )
    foreach ($c in $cands) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    return $null
}
$ConfigPath = Find-Config

# ---------- 状态 ----------
function Get-VpnState {
    $ifaces = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.InterfaceAlias -like '*Array Networks*' }
    $ip = $null; $idx = $null
    foreach ($i in $ifaces) {
        $a = (Get-NetIPAddress -InterfaceIndex $i.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Select-Object -First 1).IPAddress
        if ($a -and $a -notlike '169.254.*') { $ip = $a; $idx = $i.InterfaceIndex; break }
    }
    $split = $false
    if ($idx) {
        $vpnDefault = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                      Where-Object InterfaceIndex -eq $idx
        $physDefault = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                       Where-Object InterfaceIndex -ne $idx
        $targetRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '10.0.0.0/8' -ErrorAction SilentlyContinue |
                       Where-Object InterfaceIndex -eq $idx
        $split = [bool](-not $vpnDefault -and $physDefault -and $targetRoute)
    }
    [pscustomobject]@{ Connected = [bool]$ip; Ip = $ip; Split = $split; Index = $idx }
}

function Get-Targets {
    if (-not $ConfigPath) { return @() }
    foreach ($line in Get-Content $ConfigPath -Encoding UTF8) {
        if ($line -match '^\s*MOTIONPRO_TARGETS\s*=\s*(.+)$') {
            return @($matches[1] -split '[,;\s]+' | Where-Object { $_ })
        }
    }
    return @()
}

function Test-Sites {
    $hosts = @(Get-Targets | Where-Object { $_ -notmatch '/' } | Select-Object -First 4)
    if (-not $hosts -or $hosts.Count -eq 0) {
        # 配置里只有网段时，用默认域名做抽查
        $hosts = @('www.tongji.edu.cn', 'agi.tongji.edu.cn')
    }
    $lines = @()
    foreach ($h in $hosts) {
        $r = & curl.exe -4 -sk -o NUL -w '%{http_code} %{remote_ip}' --max-time 8 "https://$h/" 2>$null
        $lines += ("{0} -> {1}" -f $h, $r)
    }
    return ($lines -join "`r`n")
}

# ---------- 界面 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '同济 VPN 控制台'
$form.Size = New-Object System.Drawing.Size(780, 660)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$header = New-Object System.Windows.Forms.Label
$header.Text = '同济 MotionPro VPN — 一键连接 / 分流'
$header.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(16, 10)
$header.Size = New-Object System.Drawing.Size(730, 28)
$form.Controls.Add($header)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "配置: " + ($(if ($ConfigPath) { $ConfigPath } else { '未找到 motionpro.env（请先运行 setup-config.ps1）' }))
$sub.ForeColor = [System.Drawing.Color]::DimGray
$sub.Location = New-Object System.Drawing.Point(18, 40)
$sub.Size = New-Object System.Drawing.Size(730, 20)
$form.Controls.Add($sub)

$statusBox = New-Object System.Windows.Forms.GroupBox
$statusBox.Text = '当前状态'
$statusBox.Location = New-Object System.Drawing.Point(16, 64)
$statusBox.Size = New-Object System.Drawing.Size(732, 116)
$form.Controls.Add($statusBox)

$lblVpn = New-Object System.Windows.Forms.Label
$lblVpn.Location = New-Object System.Drawing.Point(14, 24)
$lblVpn.Size = New-Object System.Drawing.Size(420, 22)
$lblVpn.Text = 'VPN: -'
$statusBox.Controls.Add($lblVpn)

$lblSplit = New-Object System.Windows.Forms.Label
$lblSplit.Location = New-Object System.Drawing.Point(14, 50)
$lblSplit.Size = New-Object System.Drawing.Size(560, 22)
$lblSplit.Text = '分流: -'
$statusBox.Controls.Add($lblSplit)

$lblTargets = New-Object System.Windows.Forms.Label
$lblTargets.Location = New-Object System.Drawing.Point(14, 76)
$lblTargets.Size = New-Object System.Drawing.Size(700, 22)
$lblTargets.Text = '目标: -'
$statusBox.Controls.Add($lblTargets)

$lblBusy = New-Object System.Windows.Forms.Label
$lblBusy.Location = New-Object System.Drawing.Point(450, 24)
$lblBusy.Size = New-Object System.Drawing.Size(270, 22)
$lblBusy.Text = ''
$lblBusy.ForeColor = [System.Drawing.Color]::DarkOrange
$statusBox.Controls.Add($lblBusy)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新状态'
$btnRefresh.Location = New-Object System.Drawing.Point(620, 22)
$btnRefresh.Size = New-Object System.Drawing.Size(96, 30)
$statusBox.Controls.Add($btnRefresh)

$actions = New-Object System.Windows.Forms.GroupBox
$actions.Text = '操作'
$actions.Location = New-Object System.Drawing.Point(16, 188)
$actions.Size = New-Object System.Drawing.Size(732, 100)
$form.Controls.Add($actions)

function New-Btn($text, $x, $y, $w = 128) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    return $b
}

$btnOneClick = New-Btn '一键：连接并分流' 14 22 152
$btnOneClick.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$btnConnect  = New-Btn '连接 VPN' 178 22 104
$btnSplit    = New-Btn '分流（仅校内）' 292 22 124
$btnGlobal   = New-Btn '恢复全局' 424 22 96
$btnDisconnect = New-Btn '断开 VPN' 528 22 96
$btnTest     = New-Btn '测试访问' 14 60 152
$btnConfig   = New-Btn '打开配置' 178 60 104
$btnLog      = New-Btn '打开日志' 292 60 104
$btnReadme   = New-Btn '使用说明' 404 60 104
foreach ($b in @($btnOneClick, $btnConnect, $btnSplit, $btnGlobal, $btnDisconnect, $btnTest, $btnConfig, $btnLog, $btnReadme)) {
    $actions.Controls.Add($b)
}

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(16, 296)
$logBox.Size = New-Object System.Drawing.Size(732, 316)
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::White
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

function Write-Log([string]$text) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText(("[{0}] {1}{2}" -f $stamp, $text, "`r`n"))
    $logBox.SelectionStart = $logBox.Text.Length
    $logBox.ScrollToCaret()
    try {
        Add-Content -Path $LauncherLog -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text) -Encoding UTF8
    } catch { }
}

function Update-Status {
    $s = Get-VpnState
    if ($s.Connected) {
        $lblVpn.Text = "VPN: 已连接    IP $($s.Ip)"
        $lblVpn.ForeColor = [System.Drawing.Color]::SeaGreen
    } else {
        $lblVpn.Text = 'VPN: 未连接'
        $lblVpn.ForeColor = [System.Drawing.Color]::Firebrick
    }
    if ($s.Split) {
        $lblSplit.Text = '分流: 生效（只有校内目标走 VPN）'
        $lblSplit.ForeColor = [System.Drawing.Color]::SeaGreen
    } elseif ($s.Connected) {
        $lblSplit.Text = '分流: 未生效（全局模式，所有流量走 VPN）'
        $lblSplit.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblSplit.Text = '分流: -'
        $lblSplit.ForeColor = [System.Drawing.Color]::DimGray
    }
    $t = Get-Targets
    $lblTargets.Text = '目标: ' + $(if ($t) { $t -join ', ' } else { '（未配置）' })
}

# ---------- 后台任务（带增量输出） ----------
$script:Job = $null
$script:JobName = ''
$script:SeenLines = 0
$script:StartAt = $null

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({
    if (-not $script:Job) { return }
    # 增量读取输出：-Keep 保留，自己记录已消费的行数
    $all = @(Receive-Job -Job $script:Job -Keep -ErrorAction SilentlyContinue)
    if ($all.Count -gt $script:SeenLines) {
        for ($i = $script:SeenLines; $i -lt $all.Count; $i++) {
            $line = [string]$all[$i]
            if ($line.Trim()) { Write-Log $line.TrimEnd() }
        }
        $script:SeenLines = $all.Count
    }
    if ($script:StartAt) {
        $sec = [int]((Get-Date) - $script:StartAt).TotalSeconds
        $lblBusy.Text = "运行中… ${sec}s"
    }
    if ($script:Job.State -eq 'Running') { return }

    # 收尾
    $state = $script:Job.State
    Remove-Job $script:Job -Force -ErrorAction SilentlyContinue
    $script:Job = $null
    $script:SeenLines = 0
    $script:StartAt = $null
    $lblBusy.Text = ''
    Write-Log "—— $($script:JobName) 结束（$state）——"
    Set-Buttons $true
    Update-Status
})

function Set-Buttons([bool]$enabled) {
    foreach ($b in @($btnOneClick, $btnConnect, $btnSplit, $btnGlobal, $btnDisconnect, $btnTest)) {
        $b.Enabled = $enabled
    }
}

function Start-Task([string]$label, [string]$scriptPath, [string[]]$arguments) {
    if ($script:Job) { Write-Log '有任务在运行，请稍候…'; return }
    if (-not $scriptPath) { Write-Log "找不到脚本：$scriptPath"; return }
    Write-Log "—— $label ——"
    $cfg = $ConfigPath
    $script:JobName = $label
    $script:SeenLines = 0
    $script:StartAt = Get-Date
    $script:Job = Start-Job -ScriptBlock {
        param($sp, $args_, $cfg)
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sp)
        foreach ($a in @($args_)) { if ($null -ne $a) { $argv += $a } }
        if ($cfg) { $argv += @('-Config', $cfg) }
        & powershell.exe @argv 2>&1 | ForEach-Object { [string]$_ }
    } -ArgumentList $scriptPath, (, $arguments), $cfg
    Set-Buttons $false
}

# ---------- 事件 ----------
$btnRefresh.Add_Click({ Update-Status; Write-Log '状态已刷新' })

$btnConnect.Add_Click({
    Start-Task '连接 VPN（约 60~90 秒）' $VpnScript @('up')
})

$btnSplit.Add_Click({
    if ($script:Job) { Write-Log '有任务在运行，请稍候…'; return }
    if (-not $SplitScript) { Write-Log '找不到 split-vpn.ps1'; return }
    $cfg = $ConfigPath
    Write-Log '—— 分流（会弹 UAC，请点『是』）——'
    $script:JobName = '分流'
    $script:SeenLines = 0
    $script:StartAt = Get-Date
    $script:Job = Start-Job -ScriptBlock {
        param($split, $cfg)
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
        $a = $common + @($split, 'on', '-PreferIPv4', '-Elevate'); if ($cfg) { $a += @('-Config', $cfg) }
        & powershell.exe @a 2>&1 | ForEach-Object { [string]$_ }
        "== 等待生效（最多 45 秒；请在 UAC 弹窗点『是』） =="
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 3
            $iface = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.InterfaceAlias -like '*Array Networks*' } | Select-Object -First 1
            if (-not $iface) { continue }
            $hasTarget = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '10.0.0.0/8' -ErrorAction SilentlyContinue |
                         Where-Object InterfaceIndex -eq $iface.InterfaceIndex
            $vpnDefault = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                          Where-Object InterfaceIndex -eq $iface.InterfaceIndex
            if ($hasTarget -and -not $vpnDefault) { "分流已生效 ✔"; break }
        }
        if (-not $hasTarget -or $vpnDefault) {
            "!! 分流未生效：多半是 UAC 没点『是』。请重新点『分流（仅校内）』并在弹窗点『是』。"
        }
    } -ArgumentList $SplitScript, $cfg
    Set-Buttons $false
})

$btnGlobal.Add_Click({
    Write-Log '恢复全局需要管理员：稍后会弹出 UAC，请点「是」'
    Start-Task '恢复全局模式' $SplitScript @('off', '-Elevate')
})

$btnDisconnect.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('确定断开 VPN 吗？', '确认', 'YesNo', 'Question') -eq 'Yes') {
        Start-Task '断开 VPN' $VpnScript @('down')
    }
})

$btnOneClick.Add_Click({
    if (-not $VpnScript -or -not $SplitScript) { Write-Log '找不到脚本（vpn.ps1 / split-vpn.ps1）'; return }
    if ($script:Job) { Write-Log '有任务在运行，请稍候…'; return }
    $cfg = $ConfigPath
    Write-Log '—— 一键：连接并分流 ——'
    Write-Log '第 1 步：连接 VPN（约 60~90 秒，请勿关闭窗口）'
    $script:JobName = '一键：连接并分流'
    $script:SeenLines = 0
    $script:StartAt = Get-Date
    $script:Job = Start-Job -ScriptBlock {
        param($vpn, $split, $cfg)
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
        $a1 = $common + @($vpn, 'up'); if ($cfg) { $a1 += @('-Config', $cfg) }
        "== 第 1 步：连接 VPN（约 60~90 秒） =="
        & powershell.exe @a1 2>&1 | ForEach-Object { [string]$_ }

        # 连接结果校验：没拿到 VPN 网卡就不要继续
        $iface = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.InterfaceAlias -like '*Array Networks*' } | Select-Object -First 1
        $ip = $null
        if ($iface) {
            $ip = (Get-NetIPAddress -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Select-Object -First 1).IPAddress
        }
        if (-not $ip) {
            "!! 连接失败：没拿到 VPN 地址，跳过分流。请点『连接 VPN』重试，或查看日志。"
            return
        }
        "连接成功：$ip"

        "== 第 2 步：分流（会弹 UAC，请点『是』） =="
        $a2 = $common + @($split, 'on', '-PreferIPv4', '-Elevate'); if ($cfg) { $a2 += @('-Config', $cfg) }
        & powershell.exe @a2 2>&1 | ForEach-Object { [string]$_ }

        "== 第 3 步：等待分流生效（最多 45 秒） =="
        $ok = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 3
            $hasTarget = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '10.0.0.0/8' -ErrorAction SilentlyContinue |
                         Where-Object InterfaceIndex -eq $iface.InterfaceIndex
            $vpnDefault = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                          Where-Object InterfaceIndex -eq $iface.InterfaceIndex
            if ($hasTarget -and -not $vpnDefault) { $ok = $true; break }
        }
        if ($ok) { "分流已生效 ✔ 请点『刷新状态』确认。" }
        else { "!! 分流未生效：多半是 UAC 没点『是』。请点『分流（仅校内）』重试。" }
    } -ArgumentList $VpnScript, $SplitScript, $cfg
    Set-Buttons $false
})

$btnTest.Add_Click({
    Write-Log '—— 测试访问 ——'
    $res = Test-Sites
    Write-Log $res
})

$btnConfig.Add_Click({
    if ($ConfigPath) { Start-Process notepad.exe $ConfigPath }
    else { Write-Log '找不到 motionpro.env' }
})

$btnLog.Add_Click({
    $splitLog = Join-Path $DataDir 'split.log'
    if (Test-Path $splitLog) { Start-Process notepad.exe $splitLog }
    elseif (Test-Path $LauncherLog) { Start-Process notepad.exe $LauncherLog }
    else { Write-Log '还没有日志' }
})

$btnReadme.Add_Click({
    $readme = Join-Path (Split-Path -Parent $Root) 'README.md'
    if (-not (Test-Path $readme)) { $readme = Join-Path $Root 'README.md' }
    if (Test-Path $readme) { Start-Process notepad.exe $readme }
    else { Write-Log '找不到 README.md' }
})

$form.Add_Shown({
    Write-Log "控制台已启动（日志: $LauncherLog）"
    Write-Log "目录: $Root"
    Write-Log "连接脚本: $(if ($VpnScript) { $VpnScript } else { '未找到 vpn.ps1' })"
    Write-Log "分流脚本: $(if ($SplitScript) { $SplitScript } else { '未找到 split-vpn.ps1' })"
    Write-Log "配置文件: $(if ($ConfigPath) { $ConfigPath } else { '未找到 motionpro.env' })"
    if (-not $ConfigPath) { Write-Log '警告：未找到 motionpro.env，请先运行 setup-config.ps1' }
    if (-not $VpnScript) { Write-Log '警告：找不到 vpn.ps1' }
    if (-not $SplitScript) { Write-Log '警告：找不到 split-vpn.ps1' }
    Update-Status
    $timer.Start()
})

$form.Add_FormClosing({
    if ($script:Job) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "任务仍在运行（$($script:JobName)）。`n关闭窗口会中断它（连接/分流可能失败）。`n确定关闭吗？",
            '任务未完成', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
        try { Stop-Job $script:Job -ErrorAction SilentlyContinue } catch { }
        Remove-Job $script:Job -Force -ErrorAction SilentlyContinue
        $script:Job = $null
    }
    $timer.Stop()
})

[void]$form.ShowDialog()

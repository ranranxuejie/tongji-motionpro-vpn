# 同济 VPN 控制台（图形界面启动器）
#
# 双击「启动器.cmd」即可打开。所有操作都调用同目录（或 scripts/）下的
# vpn.ps1 / split-vpn.ps1，本文件只负责界面和状态显示。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'SilentlyContinue'

# ---------- 路径 ----------
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
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
    $targets = Get-Targets
    $hosts = $targets | Where-Object { $_ -notmatch '/' } | Select-Object -First 4
    if (-not $hosts) { return '（配置里没有域名目标，可跳过）' }
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
$form.Size = New-Object System.Drawing.Size(760, 620)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$header = New-Object System.Windows.Forms.Label
$header.Text = '同济 MotionPro VPN — 一键连接 / 分流'
$header.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(16, 12)
$header.Size = New-Object System.Drawing.Size(710, 30)
$form.Controls.Add($header)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "配置: " + ($(if ($ConfigPath) { $ConfigPath } else { '未找到 motionpro.env' }))
$sub.ForeColor = [System.Drawing.Color]::DimGray
$sub.Location = New-Object System.Drawing.Point(18, 44)
$sub.Size = New-Object System.Drawing.Size(710, 20)
$form.Controls.Add($sub)

$statusBox = New-Object System.Windows.Forms.GroupBox
$statusBox.Text = '当前状态'
$statusBox.Location = New-Object System.Drawing.Point(16, 70)
$statusBox.Size = New-Object System.Drawing.Size(712, 110)
$form.Controls.Add($statusBox)

$lblVpn = New-Object System.Windows.Forms.Label
$lblVpn.Location = New-Object System.Drawing.Point(14, 24)
$lblVpn.Size = New-Object System.Drawing.Size(340, 22)
$lblVpn.Text = 'VPN: -'
$statusBox.Controls.Add($lblVpn)

$lblSplit = New-Object System.Windows.Forms.Label
$lblSplit.Location = New-Object System.Drawing.Point(14, 50)
$lblSplit.Size = New-Object System.Drawing.Size(340, 22)
$lblSplit.Text = '分流: -'
$statusBox.Controls.Add($lblSplit)

$lblTargets = New-Object System.Windows.Forms.Label
$lblTargets.Location = New-Object System.Drawing.Point(14, 76)
$lblTargets.Size = New-Object System.Drawing.Size(680, 24)
$lblTargets.Text = '目标: -'
$statusBox.Controls.Add($lblTargets)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新状态'
$btnRefresh.Location = New-Object System.Drawing.Point(600, 20)
$btnRefresh.Size = New-Object System.Drawing.Size(96, 30)
$statusBox.Controls.Add($btnRefresh)

# 按钮区
$actions = New-Object System.Windows.Forms.GroupBox
$actions.Text = '操作'
$actions.Location = New-Object System.Drawing.Point(16, 188)
$actions.Size = New-Object System.Drawing.Size(712, 96)
$form.Controls.Add($actions)

function New-Btn($text, $x, $y, $w = 128) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    return $b
}

$btnOneClick = New-Btn '一键：连接并分流' 14 22 150
$btnOneClick.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$btnConnect  = New-Btn '连接 VPN' 176 22 110
$btnSplit    = New-Btn '分流（仅校内）' 294 22 130
$btnGlobal   = New-Btn '恢复全局' 432 22 100
$btnDisconnect = New-Btn '断开 VPN' 540 22 100
$btnTest     = New-Btn '测试访问' 14 58 150
$btnConfig   = New-Btn '打开配置' 176 58 110
$btnLog      = New-Btn '打开日志' 294 58 110
$btnReadme   = New-Btn '使用说明' 412 58 110
foreach ($b in @($btnOneClick, $btnConnect, $btnSplit, $btnGlobal, $btnDisconnect, $btnTest, $btnConfig, $btnLog, $btnReadme)) {
    $actions.Controls.Add($b)
}

# 日志区
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(16, 292)
$logBox.Size = New-Object System.Drawing.Size(712, 270)
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::White
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

function Write-Log([string]$text) {
    $logBox.AppendText(("[{0}] {1}{2}" -f (Get-Date -Format 'HH:mm:ss'), $text, "`r`n"))
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
        $lblSplit.Text = '分流: 生效（仅校内目标走 VPN）'
        $lblSplit.ForeColor = [System.Drawing.Color]::SeaGreen
    } elseif ($s.Connected) {
        $lblSplit.Text = '分流: 未生效（当前是全局模式，所有流量走 VPN）'
        $lblSplit.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblSplit.Text = '分流: -'
        $lblSplit.ForeColor = [System.Drawing.Color]::DimGray
    }
    $t = Get-Targets
    $lblTargets.Text = '目标: ' + $(if ($t) { $t -join ', ' } else { '（未配置）' })
}

# ---------- 异步执行 ----------
$script:Job = $null
$script:JobName = ''

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
    if (-not $script:Job) { return }
    if ($script:Job.State -eq 'Running') { return }
    $out = Receive-Job $script:Job 2>&1 | Out-String
    Remove-Job $script:Job -Force -ErrorAction SilentlyContinue
    $script:Job = $null
    if ($out.Trim()) { Write-Log $out.Trim() }
    Write-Log "—— $($script:JobName) 结束 ——"
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
    if (-not $scriptPath) { Write-Log '找不到脚本（vpn.ps1 / split-vpn.ps1）'; return }
    Write-Log "—— $label ——"
    $cfg = $ConfigPath
    $script:JobName = $label
    $script:Job = Start-Job -ScriptBlock {
        param($sp, $args_, $cfg)
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sp)
        foreach ($a in @($args_)) { if ($null -ne $a) { $argv += $a } }
        if ($cfg) { $argv += @('-Config', $cfg) }
        & powershell.exe @argv 2>&1 | Out-String
    } -ArgumentList $scriptPath, (, $arguments), $cfg
    Set-Buttons $false
}

# ---------- 事件 ----------
$btnRefresh.Add_Click({ Update-Status; Write-Log '状态已刷新' })

$btnConnect.Add_Click({
    Start-Task '连接 VPN' $VpnScript @('up')
})

$btnSplit.Add_Click({
    Start-Task '分流（会弹 UAC）' $SplitScript @('on', '-PreferIPv4', '-Elevate')
})

$btnGlobal.Add_Click({
    Start-Task '恢复全局模式（会弹 UAC）' $SplitScript @('off', '-Elevate')
})

$btnDisconnect.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('确定断开 VPN 吗？', '确认', 'YesNo', 'Question') -eq 'Yes') {
        Start-Task '断开 VPN' $VpnScript @('down')
    }
})

$btnOneClick.Add_Click({
    if (-not $VpnScript -or -not $SplitScript) { Write-Log '找不到脚本'; return }
    if ($script:Job) { Write-Log '有任务在运行，请稍候…'; return }
    $cfg = $ConfigPath
    Write-Log '—— 一键：连接并分流 ——'
    $script:JobName = '一键：连接并分流'
    $script:Job = Start-Job -ScriptBlock {
        param($vpn, $split, $cfg)
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
        $args1 = $common + @($vpn, 'up');      if ($cfg) { $args1 += @('-Config', $cfg) }
        "== 连接 =="
        & powershell.exe @args1 2>&1 | Out-String
        $args2 = $common + @($split, 'on', '-PreferIPv4', '-Elevate'); if ($cfg) { $args2 += @('-Config', $cfg) }
        "== 分流 =="
        & powershell.exe @args2 2>&1 | Out-String
        "== 等待生效 =="
        Start-Sleep -Seconds 25
        "== 完成，请点『刷新状态』确认 =="
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
    $log = Join-Path $env:LOCALAPPDATA 'tongji-motionpro-vpn\split.log'
    if (Test-Path $log) { Start-Process notepad.exe $log }
    else { Write-Log '还没有日志（执行过分流后才会生成）' }
})

$btnReadme.Add_Click({
    $readme = Join-Path (Split-Path -Parent $Root) 'README.md'
    if (-not (Test-Path $readme)) { $readme = Join-Path $Root 'README.md' }
    if (Test-Path $readme) { Start-Process notepad.exe $readme }
    else { Write-Log '找不到 README.md' }
})

$form.Add_Shown({
    Write-Log '就绪。点『一键：连接并分流』即可。'
    if (-not $ConfigPath) { Write-Log '警告：未找到 motionpro.env，请先运行 setup-config.ps1' }
    Update-Status
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:Job) { Remove-Job $script:Job -Force -ErrorAction SilentlyContinue }
})

[void]$form.ShowDialog()

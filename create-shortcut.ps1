# 在桌面创建「同济 VPN 控制台」快捷方式。由 create-shortcut.cmd 调用。
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here '启动器.cmd'
if (-not (Test-Path $target)) {
    $target = Join-Path $here 'launcher.cmd'
}
if (-not (Test-Path $target)) {
    Write-Error "找不到启动器（启动器.cmd / launcher.cmd），请确认本脚本与它们在同一目录"
    exit 1
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop '同济 VPN 控制台.lnk'

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = $target
$sc.WorkingDirectory = $here
$sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,77"
$sc.Description = '同济 MotionPro VPN 一键连接与分流'
$sc.Save()

Write-Host "已创建快捷方式: $lnk"
Write-Host "目标: $target"

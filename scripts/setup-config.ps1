# 生成/更新 motionpro.env 配置文件。
#
#   setup-config.ps1 -Path .\motionpro.env -Host_ vpn.example.edu.cn -User 学号 -Pass 密码 `
#                    -Targets "agi.example.edu.cn,hpc.example.edu.cn,10.67.0.0/16"
#
# 密码会明文写入文件：提醒用户不要提交到仓库，并把文件加进 .gitignore。
[CmdletBinding()]
param(
    [string]$Path = '.\motionpro.env',
    [Parameter(Mandatory = $true)][string]$Host_,
    [int]$Port = 443,
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Pass,
    [string]$Targets = '',
    [string]$Dns = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ((Test-Path $Path) -and -not $Force) {
    Write-Error "配置文件已存在: $Path（用 -Force 覆盖）"
    exit 2
}

$lines = @(
    '# MotionPro VPN 配置（含明文密码，不要提交到仓库）'
    "MOTIONPRO_HOST=$Host_"
    "MOTIONPRO_PORT=$Port"
    "MOTIONPRO_USER=$User"
    "MOTIONPRO_PASS=$Pass"
)
if ($Targets) { $lines += "MOTIONPRO_TARGETS=$Targets" }
if ($Dns) { $lines += "MOTIONPRO_DNS=$Dns" }

$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$lines | Set-Content -Path $Path -Encoding UTF8
"已写入: $((Resolve-Path $Path).Path)"
"提醒: 把 $(Split-Path -Leaf $Path) 加进 .gitignore，不要提交或外发。"

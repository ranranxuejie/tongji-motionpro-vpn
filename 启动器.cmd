@echo off
rem Double-click entry for the Tongji VPN console.
rem The launcher is loaded with explicit UTF-8 decoding (no BOM needed) and the
rem script directory is passed via TONGJI_VPN_DIR so path resolution is stable.
setlocal
set "TONGJI_VPN_DIR=%~dp0"
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ([scriptblock]::Create([IO.File]::ReadAllText($env:TONGJI_VPN_DIR + 'launcher.ps1', [Text.Encoding]::UTF8)))"
endlocal

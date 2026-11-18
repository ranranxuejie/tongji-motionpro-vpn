@echo off
rem Double-click to open the Tongji VPN console (graphical launcher).
rem This file is pure ASCII on purpose; the Chinese file name is fine.
setlocal
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher.ps1"
endlocal

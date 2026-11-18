@echo off
rem Create a desktop shortcut for the Tongji VPN console.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0create-shortcut.ps1"
echo.
pause
endlocal

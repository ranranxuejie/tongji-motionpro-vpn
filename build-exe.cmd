@echo off
rem 重新编译单文件 exe（无需安装任何工具，用系统自带的 .NET Framework 编译器）。
rem 产物: dist\同济VPN控制台.exe
setlocal
cd /d "%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo [!] 找不到 csc.exe，请确认系统安装了 .NET Framework 4.x
  pause
  exit /b 1
)
if not exist "dist" mkdir "dist"

rem 把引擎脚本复制到 build 目录，作为 exe 的内嵌资源
copy /y "common.ps1"        "build\common.ps1"        >nul
copy /y "vpn.ps1"           "build\vpn.ps1"           >nul
copy /y "split-vpn.ps1"     "build\split-vpn.ps1"     >nul

"%CSC%" /nologo /target:winexe /out:"dist\同济VPN控制台.exe" ^
  /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Management.dll ^
  /resource:"build\common.ps1,common.ps1" ^
  /resource:"build\vpn.ps1,vpn.ps1" ^
  /resource:"build\split-vpn.ps1,split-vpn.ps1" ^
  "build\launcher.cs"

if errorlevel 1 (
  echo [!] 编译失败
  pause
  exit /b 1
)
echo [OK] 已生成 dist\同济VPN控制台.exe
pause
endlocal

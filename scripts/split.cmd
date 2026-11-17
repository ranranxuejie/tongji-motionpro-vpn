@echo off
rem Run split-vpn.ps1 without changing the machine execution policy.
rem Usage: split.cmd status ^| on ^| off  [-Config .\motionpro.env] [-Reconnect] [-Elevate]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-vpn.ps1" %*

@echo off
rem Run vpn.ps1 without changing the machine execution policy.
rem Usage: vpn.cmd status ^| up ^| down  [-Config .\motionpro.env]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" %*

@echo off
rem Run diagnose.ps1 without changing the machine execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1" %*

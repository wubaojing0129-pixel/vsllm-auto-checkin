@echo off
set "VSLLM_LAUNCHER_ROOT=%~dp0"
start "VSLLM Launcher" powershell.exe -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0start-launcher.ps1"

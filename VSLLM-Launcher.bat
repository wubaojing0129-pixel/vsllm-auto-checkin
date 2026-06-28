@echo off
set "VSLLM_LAUNCHER_ROOT=%~dp0"
if not "%~1"=="" set "VSLLM_LAUNCHER_ACTION=%~1"
start "VSLLM Launcher" powershell.exe -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0start-launcher.ps1"

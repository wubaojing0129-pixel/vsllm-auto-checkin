@echo off
set "VSLLM_LAUNCHER_ROOT=%~dp0"
start "VSLLM Clean Login" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-login-browser.ps1"

$ErrorActionPreference = 'Stop'

$root = $env:VSLLM_LAUNCHER_ROOT
if (-not $root) {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$logDir = Join-Path $root 'logs'
$logPath = Join-Path $logDir 'watch-background.log'
$pidPath = Join-Path $logDir 'watch-background.pid'

if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-WatchLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

if (Test-Path -LiteralPath $pidPath) {
  $oldPid = Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
    Write-WatchLog "Background watch is already running, PID=$oldPid."
    return
  }
}

$workerPath = Join-Path $root 'watch-background-worker.ps1'
$process = Start-Process powershell.exe -WindowStyle Hidden -PassThru -WorkingDirectory $root -ArgumentList @(
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  $workerPath,
  '-Root',
  $root
)

Set-Content -LiteralPath $pidPath -Value $process.Id -Encoding ASCII
Write-WatchLog "Background watch started, PID=$($process.Id)."

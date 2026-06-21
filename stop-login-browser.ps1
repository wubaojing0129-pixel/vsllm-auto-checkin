$ErrorActionPreference = 'Continue'

$root = $env:VSLLM_LAUNCHER_ROOT
if (-not $root) {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$logDir = Join-Path $root 'logs'
$logPath = Join-Path $logDir 'launcher-ui.log'
$lockPath = Join-Path $root '.auth\login-browser.lock'

if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Stop-ProcessTree {
  param([int]$ProcessId)

  Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ProcessTree -ProcessId $_.ProcessId
  }

  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

$rootPattern = [Regex]::Escape($root)
$targets = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
  $_.CommandLine -and
  $_.CommandLine -match $rootPattern -and
  $_.CommandLine -match 'vsllm-auto\.js --login-browser|login:browser'
}

if (-not $targets) {
  Write-Log 'No leftover login-browser process found.'
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  [System.Console]::WriteLine('No leftover login-browser process found.')
  Start-Sleep -Seconds 2
  return
}

foreach ($target in $targets) {
  Stop-ProcessTree -ProcessId $target.ProcessId
  Write-Log "Stopped leftover login-browser process, PID=$($target.ProcessId)."
  [System.Console]::WriteLine("Stopped leftover login-browser process, PID=$($target.ProcessId).")
}

Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

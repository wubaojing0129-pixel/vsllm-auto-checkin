$ErrorActionPreference = 'Continue'

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

function Stop-ProcessTree {
  param([int]$ProcessId)

  Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ProcessTree -ProcessId $_.ProcessId
  }

  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

$stopped = $false
if (Test-Path -LiteralPath $pidPath) {
  $watchPid = Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($watchPid -and (Get-Process -Id $watchPid -ErrorAction SilentlyContinue)) {
    Stop-ProcessTree -ProcessId ([int]$watchPid)
    Write-WatchLog "Stopped background watch, PID=$watchPid."
    $stopped = $true
  }
}

$rootPattern = [Regex]::Escape($root)
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.CommandLine -and
    $_.CommandLine -match $rootPattern -and
    $_.CommandLine -match 'vsllm-auto\.js|vsllm-api\.js|npm run watch|npm run api:watch|VSLLM Background Watch|watch-background-worker'
  } |
  ForEach-Object {
    Stop-ProcessTree -ProcessId $_.ProcessId
    Write-WatchLog "Stopped matched background process, PID=$($_.ProcessId)."
    $stopped = $true
  }

Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue

if (-not $stopped) {
  Write-WatchLog 'No running background watch process found.'
}

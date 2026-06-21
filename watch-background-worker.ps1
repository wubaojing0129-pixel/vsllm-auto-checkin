param(
  [string]$Root
)

$ErrorActionPreference = 'Continue'

if (-not $Root) {
  $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$logDir = Join-Path $Root 'logs'
$logPath = Join-Path $logDir 'watch-background.log'

if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-WatchLog {
  param([string]$Message)
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

Set-Location -LiteralPath $Root

if (-not $env:VSLLM_DRAW_LIMIT) {
  $env:VSLLM_DRAW_LIMIT = '3'
}

if (-not $env:VSLLM_WATCH_INTERVAL_MINUTES) {
  $env:VSLLM_WATCH_INTERVAL_MINUTES = '180'
}

$env:VSLLM_SUMMARY_ONLY = '1'
$watchScript = if ($env:VSLLM_WATCH_SCRIPT) { $env:VSLLM_WATCH_SCRIPT } else { 'api:watch' }

Write-WatchLog "Background watch worker started, script=$watchScript."
npm --silent run $watchScript *>> $logPath
$exitCode = $LASTEXITCODE
Write-WatchLog "Background watch worker exited, exitCode=$exitCode."
exit $exitCode

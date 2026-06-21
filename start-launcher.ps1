$ErrorActionPreference = 'Stop'

$root = $env:VSLLM_LAUNCHER_ROOT
if (-not $root) {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$logDir = Join-Path $root 'logs'
$logPath = Join-Path $logDir 'launcher-error.log'

try {
  if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }

  $scriptPath = Join-Path $root 'launcher.ps1'
  $code = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
  Invoke-Expression $code
} catch {
  try {
    if (-not (Test-Path -LiteralPath $logDir)) {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $message = @(
      ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
      ($_.Exception.ToString())
      ''
    ) -join [Environment]::NewLine
    Add-Content -LiteralPath $logPath -Value $message -Encoding UTF8

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      ('VSLLM launcher failed. Log: ' + $logPath),
      'VSLLM Launcher',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  } catch {
  }
}

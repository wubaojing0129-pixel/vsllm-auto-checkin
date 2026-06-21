$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$releaseRoot = Join-Path $root 'release'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$liteName = "vsllm-auto-checkin-lite-$stamp"
$portableName = "vsllm-auto-checkin-portable-$stamp"
$liteDir = Join-Path $releaseRoot $liteName
$portableDir = Join-Path $releaseRoot $portableName
$liteZip = Join-Path $releaseRoot "$liteName.zip"
$portableZip = Join-Path $releaseRoot "$portableName.zip"

$commonItems = @(
  'README.md',
  'package.json',
  'package-lock.json',
  'launcher.ps1',
  'start-launcher.ps1',
  'install-deps.ps1',
  'start-watch-background.ps1',
  'stop-watch-background.ps1',
  'stop-login-browser.ps1',
  'watch-background-worker.ps1',
  'src'
)

function Copy-CommonItems {
  param([string]$TargetDir)

  New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
  foreach ($item in $commonItems) {
    $source = Join-Path $root $item
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Missing release item: $item"
    }

    $destination = Join-Path $TargetDir $item
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
  }

  Get-ChildItem -LiteralPath $root -File -Filter '*.bat' |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetDir $_.Name) -Force
    }

  Get-ChildItem -LiteralPath $root -File -Filter '*.txt' |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetDir $_.Name) -Force
    }
}

function Add-PortableRuntime {
  param([string]$TargetDir)

  $nodeModules = Join-Path $root 'node_modules'
  if (-not (Test-Path -LiteralPath (Join-Path $nodeModules 'playwright\package.json'))) {
    throw 'node_modules/playwright was not found. Run VSLLM-安装依赖.bat or npm install before building portable package.'
  }

  Copy-Item -LiteralPath $nodeModules -Destination (Join-Path $TargetDir 'node_modules') -Recurse -Force

  $nodeCommand = Get-Command node -ErrorAction Stop
  $runtimeDir = Join-Path $TargetDir 'runtime'
  New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
  Copy-Item -LiteralPath $nodeCommand.Source -Destination (Join-Path $runtimeDir 'node.exe') -Force

  $notice = @(
    'This package includes a local node.exe runtime copied from the build machine.',
    'It is used only when runtime\node.exe exists, so friends can run VSLLM-Launcher.bat without installing Node.js.',
    'Node.js project and license information: https://nodejs.org/'
  ) -join [Environment]::NewLine
  Set-Content -LiteralPath (Join-Path $runtimeDir 'NODE_RUNTIME_NOTICE.txt') -Value $notice -Encoding UTF8
}

function Compress-ReleaseFolder {
  param(
    [string]$Folder,
    [string]$ZipPath
  )

  Compress-Archive -LiteralPath $Folder -DestinationPath $ZipPath -CompressionLevel Optimal
}

function Test-ZipHasSensitiveEntries {
  param([string]$ZipPath)

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    return @(
      $zip.Entries |
        Where-Object {
          $name = $_.FullName -replace '\\', '/'
          $name -match '(^|/)(\.auth|logs|screenshots|\.git|\.tmp-site)(/|$)' -or
          $name -match '(^|/)\.env(\.|$)' -or
          $name -match 'draw-state\.json|launcher-action\.json|cookie|Cookies'
        } |
        Select-Object -ExpandProperty FullName
    )
  } finally {
    $zip.Dispose()
  }
}

New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

Copy-CommonItems -TargetDir $liteDir
Copy-CommonItems -TargetDir $portableDir
Add-PortableRuntime -TargetDir $portableDir

Compress-ReleaseFolder -Folder $liteDir -ZipPath $liteZip
Compress-ReleaseFolder -Folder $portableDir -ZipPath $portableZip

$liteSensitive = Test-ZipHasSensitiveEntries -ZipPath $liteZip
$portableSensitive = Test-ZipHasSensitiveEntries -ZipPath $portableZip
if ($liteSensitive.Count -gt 0 -or $portableSensitive.Count -gt 0) {
  Write-Host 'Sensitive entries were found in release zips:'
  $liteSensitive | ForEach-Object { Write-Host "lite: $_" }
  $portableSensitive | ForEach-Object { Write-Host "portable: $_" }
  exit 2
}

$result = [PSCustomObject]@{
  liteZip = $liteZip
  portableZip = $portableZip
  liteSizeMB = [Math]::Round((Get-Item -LiteralPath $liteZip).Length / 1MB, 2)
  portableSizeMB = [Math]::Round((Get-Item -LiteralPath $portableZip).Length / 1MB, 2)
}

$result | ConvertTo-Json

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
  'stop-login-browser.ps1',
  'src'
)

function ConvertFrom-CodePoints {
  param([int[]]$CodePoints)
  return -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Join-NameParts {
  param(
    [string]$Prefix,
    [int[]]$CodePoints,
    [string]$Suffix
  )

  return $Prefix + (ConvertFrom-CodePoints $CodePoints) + $Suffix
}

$batItems = @(
  'VSLLM-Launcher.bat',
  (Join-NameParts 'VSLLM-' @(0x5B89, 0x88C5, 0x4F9D, 0x8D56) '.bat'),
  'Install-Dependencies.bat'
)

$textItems = @(
  (Join-NameParts '' @(0x7FA4, 0x53CB, 0x4F7F, 0x7528, 0x8BF4, 0x660E) '.txt')
)

function Copy-CommonItems {
  param([string]$TargetDir)

  New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
  foreach ($item in ($commonItems + $batItems + $textItems)) {
    $source = Join-Path $root $item
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Missing release item: $item"
    }

    $destination = Join-Path $TargetDir $item
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
  }
}

function Add-PortableRuntime {
  param([string]$TargetDir)

  $nodeModules = Join-Path $root 'node_modules'
  if (-not (Test-Path -LiteralPath (Join-Path $nodeModules 'playwright\package.json'))) {
    throw 'node_modules/playwright was not found. Run Install-Dependencies.bat or npm ci before building portable package.'
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

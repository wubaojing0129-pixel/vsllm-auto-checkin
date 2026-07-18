param(
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = $env:VSLLM_LAUNCHER_ROOT
if (-not $root) {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Pause-BeforeExit {
  if ($NoPause -or $env:VSLLM_INSTALL_NO_PAUSE -eq '1') {
    return
  }

  Write-Host ''
  Read-Host '按 Enter 关闭窗口'
}

try {
  Set-Location -LiteralPath $root
  Write-Host 'VSLLM 签到+任务+抽奖工具 - 依赖安装/修复'
  Write-Host ('目录：' + $root)
  Write-Host ''

  $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $nodeCommand -or -not $npmCommand) {
    Write-Host '未检测到 Node.js / npm。'
    Write-Host '请先安装 Node.js 18 或更高版本：https://nodejs.org/'
    Pause-BeforeExit
    exit 1
  }

  $nodeExecutable = $nodeCommand.Source
  $npmCmdCandidate = Join-Path (Split-Path -Parent $nodeExecutable) 'npm.cmd'
  $npmExecutable = if (Test-Path -LiteralPath $npmCmdCandidate) {
    $npmCmdCandidate
  } else {
    $npmCommand.Source
  }

  $nodeVersion = (& $nodeExecutable --version).Trim()
  $npmVersion = (& $npmExecutable --version).Trim()
  Write-Host ('检测到 Node.js：' + $nodeVersion)
  Write-Host ('检测到 npm：' + $npmVersion)
  Write-Host ('Node.js 路径：' + $nodeExecutable)
  Write-Host ('npm 路径：' + $npmExecutable)

  $majorText = $nodeVersion.TrimStart('v').Split('.')[0]
  $major = 0
  [void][int]::TryParse($majorText, [ref]$major)
  if ($major -lt 18) {
    Write-Host 'Node.js 版本太低，请升级到 18 或更高版本。'
    Pause-BeforeExit
    exit 1
  }

  if (-not (Test-Path -LiteralPath (Join-Path $root 'package.json'))) {
    throw '当前目录缺少 package.json，请确认压缩包已经完整解压。'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $root 'package-lock.json'))) {
    throw '当前目录缺少 package-lock.json，请确认压缩包已经完整解压。'
  }

  Write-Host ''
  Write-Host '正在按 package-lock.json 安装项目依赖，请稍等...'
  & $npmExecutable ci --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) {
    throw "npm ci 失败，退出码：$LASTEXITCODE"
  }

  Write-Host ''
  Write-Host '正在校验 Playwright 依赖...'
  & $nodeExecutable -e "import('playwright').then(()=>console.log('Playwright OK')).catch((e)=>{console.error(e);process.exit(1)})"
  if ($LASTEXITCODE -ne 0) {
    throw "Playwright 校验失败，退出码：$LASTEXITCODE"
  }

  Write-Host ''
  Write-Host '安装完成。现在可以双击 VSLLM-Launcher.bat 打开控制台。'
  Pause-BeforeExit
  exit 0
} catch {
  Write-Host ''
  Write-Host '安装失败：'
  Write-Host $_.Exception.Message
  Write-Host ''
  Write-Host '请确认压缩包已经完整解压，并把这个窗口里的错误截图发给作者排查。'
  Pause-BeforeExit
  exit 1
}

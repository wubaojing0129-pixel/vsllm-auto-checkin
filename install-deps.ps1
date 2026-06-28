$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$root = $env:VSLLM_LAUNCHER_ROOT
if (-not $root) {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Pause-BeforeExit {
  Write-Host ''
  Read-Host '按 Enter 关闭窗口'
}

try {
  Set-Location -LiteralPath $root
  Write-Host 'VSLLM 签到+抽奖工具 - 依赖安装/修复'
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

  $nodeVersion = (& node --version).Trim()
  Write-Host ('检测到 Node.js：' + $nodeVersion)

  $majorText = $nodeVersion.TrimStart('v').Split('.')[0]
  $major = 0
  [void][int]::TryParse($majorText, [ref]$major)
  if ($major -lt 18) {
    Write-Host 'Node.js 版本太低，请升级到 18 或更高版本。'
    Pause-BeforeExit
    exit 1
  }

  Write-Host ''
  Write-Host '正在按 package-lock.json 安装项目依赖，请稍等...'
  & npm ci
  if ($LASTEXITCODE -ne 0) {
    throw "npm ci 失败，退出码：$LASTEXITCODE"
  }

  Write-Host ''
  Write-Host '正在校验 Playwright 依赖...'
  & node -e "import('playwright').then(()=>console.log('Playwright OK')).catch((e)=>{console.error(e);process.exit(1)})"
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
  Write-Host '可以把这个窗口里的错误截图发给作者排查。'
  Pause-BeforeExit
  exit 1
}

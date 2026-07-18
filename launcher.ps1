$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:RootDir = if ($env:VSLLM_LAUNCHER_ROOT) {
  (Resolve-Path -LiteralPath $env:VSLLM_LAUNCHER_ROOT).Path
} elseif ($PSScriptRoot) {
  $PSScriptRoot
} else {
  (Get-Location).Path
}

$script:CurrentProcess = $null
$script:CurrentProcessTitle = ''
$script:ReallyExit = $false
$script:TrayMessageShown = $false
$script:LogDir = Join-Path $script:RootDir 'logs'
$script:LauncherLogPath = Join-Path $script:LogDir 'launcher-ui.log'
$script:DrawHistoryPath = Join-Path $script:LogDir 'draw-history.log'
$script:DrawStatePath = Join-Path $script:LogDir 'draw-state.json'
$script:ActionRequestPath = Join-Path $script:LogDir 'launcher-action.json'
$script:StartupAction = $env:VSLLM_LAUNCHER_ACTION
$script:StartupActionConsumed = $false
$script:CurrentTaskLogPath = ''
$script:CurrentTaskLogLineCount = 0
$script:WatchActive = $false
$script:WatchRound = 0
$script:WatchNextRunAt = $null
$script:DrawHistoryLineCount = 0
$script:CheckInHistoryLineCount = 0
$script:LastActionRequestId = ''
$script:InstanceMutex = $null

if (-not (Test-Path -LiteralPath $script:LogDir)) {
  New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

function Get-LauncherMutexName {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:RootDir.ToLowerInvariant())
    $hash = $sha.ComputeHash($bytes)
    $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 32)
    return "Local\VSLLM-Launcher-$hex"
  } finally {
    $sha.Dispose()
  }
}

function Get-ExistingActionRequestId {
  if (-not (Test-Path -LiteralPath $script:ActionRequestPath)) {
    return ''
  }

  try {
    $request = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ActionRequestPath | ConvertFrom-Json
    return [string]$request.id
  } catch {
    return ''
  }
}

function Send-ActionToRunningLauncher {
  param([string]$Action)

  $actionText = if ([string]::IsNullOrWhiteSpace($Action)) { 'show' } else { $Action.Trim() }
  $payload = [PSCustomObject]@{
    id = [Guid]::NewGuid().ToString()
    action = $actionText
    createdAt = (Get-Date).ToString('o')
    root = $script:RootDir
  }

  try {
    $payload | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:ActionRequestPath -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $script:LogDir 'launcher-ui.log') -Encoding UTF8 -Value ("[{0}] 已把启动动作转给正在运行的控制台：{1}" -f (Get-Date -Format 'HH:mm:ss'), $actionText)
  } catch {
  }
}

function Initialize-SingleInstance {
  $createdNew = $false
  $mutexName = Get-LauncherMutexName
  $script:InstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

  if (-not $createdNew) {
    Send-ActionToRunningLauncher -Action $script:StartupAction
    exit 0
  }

  $script:LastActionRequestId = Get-ExistingActionRequestId
}

Initialize-SingleInstance

function Release-SingleInstance {
  if (-not $script:InstanceMutex) {
    return
  }

  try {
    $script:InstanceMutex.ReleaseMutex()
  } catch {
  }

  try {
    $script:InstanceMutex.Dispose()
  } catch {
  }

  $script:InstanceMutex = $null
}

function New-Font($size, $style = [System.Drawing.FontStyle]::Regular) {
  New-Object System.Drawing.Font('Microsoft YaHei UI', $size, $style)
}

function Append-Log {
  param([string]$Message)

  $messageText = if ($null -eq $Message) { '' } else { [string]$Message }
  $line = if ($messageText -match '^\[\d{4}[-/]\d{1,2}[-/]\d{1,2}[^\]]*\]') {
    "$messageText`r`n"
  } else {
    "[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $messageText
  }

  try {
    Add-Content -LiteralPath $script:LauncherLogPath -Value $line -Encoding UTF8
  } catch {
  }

  if ($messageText -match '抽奖日志') {
    Update-HistorySummary
  }

  if (-not $script:OutputBox -or $script:OutputBox.IsDisposed) {
    return
  }

  if ($script:OutputBox.InvokeRequired) {
    $script:OutputBox.BeginInvoke([Action[string]]{
      param([string]$Text)
      $script:OutputBox.AppendText($Text)
      $script:OutputBox.SelectionStart = $script:OutputBox.TextLength
      $script:OutputBox.ScrollToCaret()
    }, $line) | Out-Null
    return
  }

  $script:OutputBox.AppendText($line)
  $script:OutputBox.SelectionStart = $script:OutputBox.TextLength
  $script:OutputBox.ScrollToCaret()
}

function Show-MainWindow {
  if (-not $script:Form -or $script:Form.IsDisposed) {
    return
  }

  $script:Form.ShowInTaskbar = $true
  $script:Form.Show()
  $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
  $script:Form.Activate()
  $script:Form.TopMost = $true
  $script:Form.TopMost = $false
}

function Show-ErrorMessage {
  param(
    [string]$Title,
    [string]$Message
  )

  [System.Windows.Forms.MessageBox]::Show(
    $Message,
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
}

function Read-DrawState {
  if (-not (Test-Path -LiteralPath $script:DrawStatePath)) {
    return $null
  }

  try {
    return (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:DrawStatePath | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Test-AuthExpiredState {
  $state = Read-DrawState
  return ($state -and [string]$state.lastStatus -eq 'auth-expired')
}

function Get-BalanceSummaryText {
  $state = Read-DrawState
  if (-not $state -or -not $state.accountBalance) {
    return '余额：未读取'
  }

  $balance = $state.accountBalance
  $valueText = if ($balance.valueText) { [string]$balance.valueText } elseif ($balance.value -ne $null) { [string]$balance.value } else { '' }
  $unitText = if ($balance.unit) { [string]$balance.unit } else { '' }

  if ($valueText) {
    $compactValue = ($valueText -replace '\s+', ' ').Trim()
    if ($unitText) {
      return "余额：$compactValue $unitText"
    }
    return "余额：$compactValue"
  }

  $display = [string]$balance.displayText
  if ($display) {
    $display = ($display -replace '\s+', ' ').Trim()
    if ($display) {
      return "余额：$display"
    }
  }

  return '余额：未读取'
}

function Hide-ToTray {
  if (-not $script:Form -or $script:Form.IsDisposed) {
    return
  }

  $script:Form.Hide()
  $script:Form.ShowInTaskbar = $false

  if ($script:TrayIcon -and -not $script:TrayMessageShown) {
    $script:TrayIcon.BalloonTipTitle = 'VSLLM 签到+任务+抽奖控制台'
    $script:TrayIcon.BalloonTipText = '控制台已常驻右下角托盘。双击图标可以重新打开。'
    $script:TrayIcon.ShowBalloonTip(3000)
    $script:TrayMessageShown = $true
  }
}

function Set-RunningState {
  param([bool]$IsRunning)

  $busy = $IsRunning -or $script:WatchActive
  if ($script:BalanceLabel -and -not $script:BalanceLabel.IsDisposed) {
    $script:BalanceLabel.Text = Get-BalanceSummaryText
  }
  $script:LoginButton.Enabled = -not $busy
  $script:RunButton.Enabled = -not $busy
  $script:WatchButton.Enabled = -not $busy
  if ($script:RefreshBalanceButton -and -not $script:RefreshBalanceButton.IsDisposed) {
    $script:RefreshBalanceButton.Enabled = -not $busy
  }
  $script:DrawLimitBox.Enabled = -not $busy
  $script:DailyTasksCheckBox.Enabled = -not $busy
  $script:IntervalBox.Enabled = -not $busy
  $script:StopButton.Enabled = $true
  $script:StatusLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
  if ($IsRunning) {
    $script:StatusLabel.Text = '状态：正在执行签到+任务+翻牌'
  } elseif ($script:WatchActive -and $script:WatchNextRunAt) {
    $remaining = Format-WaitTime ($script:WatchNextRunAt - (Get-Date))
    $script:StatusLabel.Text = '状态：守护等待中，下一轮约 ' + $script:WatchNextRunAt.ToString('HH:mm:ss') + '，剩余 ' + $remaining
  } elseif ($script:WatchActive) {
    $script:StatusLabel.Text = '状态：守护已启动'
  } elseif (Test-AuthExpiredState) {
    $script:StatusLabel.Text = '状态：登录失效，请点[首次登录]重新登录'
    $script:StatusLabel.ForeColor = [System.Drawing.Color]::DarkRed
  } else {
    $script:StatusLabel.Text = '状态：准备就绪'
  }
}

function Flush-CurrentTaskLog {
  if (-not $script:CurrentTaskLogPath -or -not (Test-Path -LiteralPath $script:CurrentTaskLogPath)) {
    return
  }

  try {
    $lines = @(Get-Content -LiteralPath $script:CurrentTaskLogPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    for ($index = $script:CurrentTaskLogLineCount; $index -lt $lines.Count; $index += 1) {
      $taskLine = ([string]$lines[$index]) -replace "`0", ''
      if (-not $taskLine.Trim()) {
        continue
      }
      if ($taskLine -match '签到日志：|抽奖日志：本轮第|抽奖日志：冷却中|抽奖日志：第 \d+ 次尝试|抽奖日志：本轮次数已用完') {
        continue
      }
      if ($taskLine) {
        Append-Log $taskLine
      }
    }
    $script:CurrentTaskLogLineCount = $lines.Count
  } catch {
  }
}

function Complete-CurrentProcess {
  if (-not $script:CurrentProcess) {
    return
  }

  Flush-CurrentTaskLog
  Flush-HistoryLogs

  if (-not $script:CurrentProcess.HasExited) {
    return
  }

  $process = $script:CurrentProcess
  $title = $script:CurrentProcessTitle
  $exitCode = $process.ExitCode

  $script:CurrentProcess = $null
  $script:CurrentProcessTitle = ''
  Flush-CurrentTaskLog
  Flush-HistoryLogs
  Update-HistorySummary
  $script:CurrentTaskLogPath = ''
  $script:CurrentTaskLogLineCount = 0

  if ($script:TaskCheckTimer) {
    $script:TaskCheckTimer.Stop()
  }

  Append-Log ("任务结束：{0}，退出码 {1}" -f $title, $exitCode)

  if ($title -eq '守护检查' -and $script:WatchActive -and $exitCode -eq 0) {
    Schedule-NextWatchCheck
    return
  }

  if ($title -eq '守护检查') {
    $script:WatchActive = $false
    if ($script:WatchTimer) {
      $script:WatchTimer.Stop()
    }
  }

  Set-RunningState $false

  if ($exitCode -ne 0) {
    Show-MainWindow
    if (Test-AuthExpiredState) {
      Set-RunningState $false
      Show-ErrorMessage '登录状态失效' ("VSLLM 登录状态已经失效。`r`n`r`n请点[首次登录]重新登录，登录成功后再点[开始守护]。`r`n`r`n日志：{0}" -f $script:LauncherLogPath)
    } else {
      Show-ErrorMessage '任务异常退出' ("任务：{0}`r`n退出码：{1}`r`n`r`n请查看面板输出，或打开日志：`r`n{2}" -f $title, $exitCode, $script:LauncherLogPath)
    }
  }
}

function Stop-ProcessTree {
  param([int]$ProcessId)

  try {
    Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" | ForEach-Object {
      Stop-ProcessTree -ProcessId $_.ProcessId
    }
  } catch {
  }

  try {
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
  } catch {
  }
}

function Stop-CurrentTask {
  if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
    Stop-ProcessTree -ProcessId $script:CurrentProcess.Id
    Append-Log '已请求停止当前任务。'
  }

  $script:CurrentProcess = $null
  $script:CurrentProcessTitle = ''
  $script:CurrentTaskLogPath = ''
  $script:CurrentTaskLogLineCount = 0
  if ($script:TaskCheckTimer) {
    $script:TaskCheckTimer.Stop()
  }
  Set-RunningState $false
}

function Stop-LegacyBackgroundWatch {
  $pidPath = Join-Path $script:LogDir 'watch-background.pid'
  if (-not (Test-Path -LiteralPath $pidPath)) {
    return
  }

  $oldPid = Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
    Stop-ProcessTree -ProcessId ([int]$oldPid)
    Append-Log ("已停止旧后台守候进程，PID={0}。" -f $oldPid)
  }

  Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Stop-ProjectWatchProcesses {
  try {
    $escapedRoot = [Regex]::Escape($script:RootDir)
    $matches = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ProcessId -ne $PID -and
      $_.CommandLine -and
      $_.CommandLine -match $escapedRoot -and
      (
        $_.CommandLine -match 'api:watch' -or
        $_.CommandLine -match 'vsllm-api\.js\s+--watch'
      )
    }

    foreach ($match in $matches) {
      Stop-ProcessTree -ProcessId $match.ProcessId
      Append-Log ("已停止本项目守护进程，PID={0}。" -f $match.ProcessId)
    }
  } catch {
  }
}

function Stop-AllTasks {
  Stop-WatchMode
  Stop-CurrentTask
  Stop-ProjectWatchProcesses
}

function Test-LoginBrowserRunning {
  try {
    $escapedRoot = [Regex]::Escape($script:RootDir)
    $matches = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match $escapedRoot -and
      $_.CommandLine -match 'vsllm-auto\.js --login-browser|login:browser'
    }
    return [bool]$matches
  } catch {
    return $false
  }
}

function Exit-Launcher {
  if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
      '当前任务还在运行，是否停止任务并退出程序？',
      '确认退出',
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
      return
    }

    Stop-CurrentTask
  }

  $script:ReallyExit = $true
  if ($script:TrayIcon) {
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    $script:TrayIcon = $null
  }

  Release-SingleInstance

  if ($script:Form -and -not $script:Form.IsDisposed) {
    $script:Form.Close()
  }
}

function New-NpmCommand {
  param(
    [string]$ScriptName,
    [string]$RedirectPath = ''
  )

  $drawLimit = [int]$script:DrawLimitBox.Value
  $watchInterval = [int]$script:IntervalBox.Value
  $dailyTasks = if ($script:DailyTasksCheckBox.Checked) { '1' } else { '0' }
  $escapedRoot = $script:RootDir.Replace("'", "''")
  $scriptArgs = switch ($ScriptName) {
    'login' { @('src/vsllm-auto.js', '--login') }
    'login:auto' { @('src/vsllm-auto.js', '--login-auto') }
    'login:browser' { @('src/vsllm-auto.js', '--login-browser') }
    'run' { @('src/vsllm-auto.js') }
    'run:headed' { @('src/vsllm-auto.js', '--headed') }
    'api' { @('src/vsllm-api.js') }
    'api:balance' { @('src/vsllm-api.js', '--balance') }
    'api:watch' { @('src/vsllm-api.js', '--watch') }
    'api:headed' { @('src/vsllm-api.js', '--headed') }
    'watch' { @('src/vsllm-auto.js', '--watch') }
    'watch:headed' { @('src/vsllm-auto.js', '--watch', '--headed') }
    default { @() }
  }

  if ($scriptArgs.Count -gt 0) {
    $quotedArgs = ($scriptArgs | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ' '
    $runLine = "& `$nodeExe $quotedArgs"
  } else {
    $runLine = "npm --silent run $ScriptName"
  }

  if ($RedirectPath) {
    $escapedRedirectPath = $RedirectPath.Replace("'", "''")
    $runLine = "$runLine 2>&1 | ForEach-Object { Add-Content -LiteralPath '$escapedRedirectPath' -Value `$_.ToString() -Encoding UTF8 }"
  }

  @"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location -LiteralPath '$escapedRoot'
`$bundledNode = Join-Path '$escapedRoot' 'runtime\node.exe'
if (Test-Path -LiteralPath `$bundledNode) {
  `$nodeExe = `$bundledNode
} else {
  `$nodeCommand = Get-Command node -ErrorAction Stop
  `$nodeExe = `$nodeCommand.Source
}
`$env:VSLLM_DRAW_LIMIT = '$drawLimit'
`$env:VSLLM_DAILY_TASKS = '$dailyTasks'
`$env:VSLLM_WATCH_INTERVAL_MINUTES = '$watchInterval'
`$env:VSLLM_WATCH_BUFFER_SECONDS = '10'
Remove-Item Env:VSLLM_WATCH_BUFFER_MINUTES -ErrorAction SilentlyContinue
if ('$ScriptName' -like 'api*') {
  `$env:VSLLM_SUMMARY_ONLY = '1'
} else {
  Remove-Item Env:VSLLM_SUMMARY_ONLY -ErrorAction SilentlyContinue
}
$runLine
"@
}

function Test-RuntimeReady {
  $bundledNode = Join-Path $script:RootDir 'runtime\node.exe'
  $hasBundledNode = Test-Path -LiteralPath $bundledNode
  $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
  $installBat = Join-Path $script:RootDir 'VSLLM-安装依赖.bat'

  if (-not $hasBundledNode -and -not $nodeCommand) {
    $message = "未检测到 Node.js，也没有找到包内 runtime\node.exe。`r`n`r`n请先安装 Node.js 18 或更高版本，然后重新打开本工具。`r`n官网：https://nodejs.org/"
    Append-Log '运行环境检查失败：未检测到 Node.js，也没有找到包内 runtime/node.exe。'
    Show-ErrorMessage '缺少运行环境' $message
    return $false
  }

  $nodeExe = if ($hasBundledNode) { $bundledNode } else { $nodeCommand.Source }
  try {
    $nodeVersionText = (& $nodeExe --version 2>$null).Trim()
    $majorText = $nodeVersionText.TrimStart('v').Split('.')[0]
    $major = 0
    [void][int]::TryParse($majorText, [ref]$major)
    if ($major -lt 18) {
      $message = "当前 Node.js 版本太低：$nodeVersionText`r`n`r`n请升级到 Node.js 18 或更高版本，或者使用带 runtime 的免安装版。"
      Append-Log ("运行环境检查失败：Node.js 版本过低：{0}" -f $nodeVersionText)
      Show-ErrorMessage 'Node.js 版本过低' $message
      return $false
    }
  } catch {
    $message = "无法检测 Node.js 版本。`r`n`r`n路径：$nodeExe`r`n错误：$($_.Exception.Message)"
    Append-Log ("运行环境检查失败：无法检测 Node.js 版本：{0}" -f $_.Exception.Message)
    Show-ErrorMessage 'Node.js 检查失败' $message
    return $false
  }

  $playwrightPackage = Join-Path $script:RootDir 'node_modules\playwright\package.json'
  if (-not (Test-Path -LiteralPath $playwrightPackage)) {
    $installAliasBat = Join-Path $script:RootDir 'Install-Dependencies.bat'
    if (-not $npmCommand) {
      $message = "还没有安装项目依赖，并且未检测到 npm。`r`n`r`n请先安装 Node.js 18 或更高版本，再双击运行：`r`n$installBat`r`n或：`r`n$installAliasBat"
      Append-Log '运行环境检查失败：未检测到 node_modules/playwright，也未检测到 npm。'
      Show-ErrorMessage '缺少项目依赖' $message
      return $false
    }

    $message = "还没有安装项目依赖。`r`n`r`n请先双击运行：`r`n$installBat`r`n或：`r`n$installAliasBat`r`n`r`n安装完成后再重新打开 VSLLM-Launcher.bat。"
    Append-Log '运行环境检查失败：未检测到 node_modules/playwright，请先安装依赖。'
    Show-ErrorMessage '缺少项目依赖' $message
    return $false
  }

  return $true
}

function Invoke-VisibleNpmScript {
  param(
    [string]$ScriptName,
    [string]$Title
  )

  Show-MainWindow

  if (-not (Test-RuntimeReady)) {
    return
  }

  [System.Windows.Forms.MessageBox]::Show(
    "即将打开一个前台命令窗口。请按窗口提示完成登录。`r`n`r`n如果遇到 Google 不安全浏览器提示，请确认使用的是新的普通浏览器登录流程。",
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  ) | Out-Null

  $baseCommand = New-NpmCommand -ScriptName $ScriptName
  $visibleCommand = @"
try {
$baseCommand
  `$exitCode = `$LASTEXITCODE
  Write-Host ''
  Write-Host ('任务结束，退出码：' + `$exitCode)
} catch {
  Write-Host ''
  Write-Host '任务异常：'
  Write-Host `$_.Exception.ToString()
  `$exitCode = 1
}
Write-Host ''
Read-Host '按 Enter 关闭这个登录窗口'
exit `$exitCode
"@
  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($visibleCommand))

  try {
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
      Append-Log '已有任务正在运行，请先停止或等待结束。'
      return
    }

    $process = Start-Process powershell.exe -PassThru -WorkingDirectory $script:RootDir -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      $encodedCommand
    )
    $script:CurrentProcess = $process
    $script:CurrentProcessTitle = $Title
    Set-RunningState $true
    if ($script:TaskCheckTimer) {
      $script:TaskCheckTimer.Start()
    }
    Append-Log ("已打开前台窗口：{0}" -f $Title)
  } catch {
    Append-Log ("打开前台窗口失败：{0}" -f $_.Exception.Message)
    Show-ErrorMessage '启动失败' ("打开前台窗口失败：`r`n{0}" -f $_.Exception.Message)
  }
}

function Invoke-NpmScript {
  param(
    [string]$ScriptName,
    [string]$Title
  )

  if (-not (Test-RuntimeReady)) {
    return
  }

  if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
    Append-Log '已有任务正在运行，请先停止或等待结束。'
    return
  }

  if ($ScriptName -match '^(api|watch|run)') {
    if (Test-LoginBrowserRunning) {
      Append-Log '检测到首次登录窗口还没结束。请先完成登录，关闭登录浏览器，并在登录命令窗口按 Enter。'
      Show-MainWindow
      [System.Windows.Forms.MessageBox]::Show(
        "首次登录流程还没结束。`r`n`r`n请先完成登录，关闭登录浏览器窗口，然后回到登录命令窗口按 Enter，再运行 API。",
        '请先完成首次登录',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
      ) | Out-Null
      return
    }
  }

  $taskStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $safeTitle = ($Title -replace '[^\w\u4e00-\u9fff-]+', '-').Trim('-')
  if (-not $safeTitle) {
    $safeTitle = $ScriptName.Replace(':', '-')
  }
  $script:CurrentTaskLogPath = Join-Path $script:LogDir ("task-{0}-{1}.log" -f $taskStamp, $safeTitle)
  $script:CurrentTaskLogLineCount = 0
  Set-Content -LiteralPath $script:CurrentTaskLogPath -Encoding UTF8 -Value ("[{0}] 任务日志启动：{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Title)

  $command = New-NpmCommand -ScriptName $ScriptName -RedirectPath $script:CurrentTaskLogPath
  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
  $psi.WorkingDirectory = $script:RootDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $false
  $psi.RedirectStandardError = $false
  $psi.CreateNoWindow = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  $process.EnableRaisingEvents = $true

  Append-Log ("开始：{0}" -f $Title)
  Set-RunningState $true
  $script:CurrentProcess = $process
  $script:CurrentProcessTitle = $Title
  try {
    [void]$process.Start()
    if ($script:TaskCheckTimer) {
      $script:TaskCheckTimer.Start()
    }
  } catch {
    $script:CurrentProcess = $null
    $script:CurrentProcessTitle = ''
    $script:CurrentTaskLogPath = ''
    $script:CurrentTaskLogLineCount = 0
    Set-RunningState $false
    Append-Log ("启动任务失败：{0}" -f $_.Exception.Message)
    Show-ErrorMessage '启动失败' ("启动任务失败：`r`n{0}" -f $_.Exception.Message)
  }
}

function Open-Folder {
  param([string]$Folder)

  if (-not (Test-Path -LiteralPath $Folder)) {
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
  }

  Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Folder)
}

function Clear-RuntimeLogs {
  $answer = [System.Windows.Forms.MessageBox]::Show(
    "将清理旧的任务日志和窗口日志。`r`n`r`n不会删除抽奖记录、签到记录和登录信息。",
    '清理旧日志',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )

  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
    return
  }

  $removed = 0
  foreach ($pattern in @('task-*.log', 'watch-background.log')) {
    $files = @(Get-ChildItem -LiteralPath $script:LogDir -Filter $pattern -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
      if ($script:CurrentTaskLogPath -and $file.FullName -eq $script:CurrentTaskLogPath) {
        continue
      }

      try {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        $removed += 1
      } catch {
      }
    }
  }

  try {
    Set-Content -LiteralPath $script:LauncherLogPath -Encoding UTF8 -Value ''
  } catch {
  }

  if ($script:OutputBox -and -not $script:OutputBox.IsDisposed) {
    $script:OutputBox.Clear()
  }
  Append-Log ("已清理旧任务日志 {0} 个；抽奖记录和签到记录已保留。" -f $removed)
}

function Get-StartupShortcutPath {
  $startupDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
  return (Join-Path $startupDir 'VSLLM 签到+抽奖控制台.lnk')
}

function Test-StartupGuardEnabled {
  return (Test-Path -LiteralPath (Get-StartupShortcutPath))
}

function Update-StartupButton {
  if (-not $script:StartupButton -or $script:StartupButton.IsDisposed) {
    return
  }

  if (Test-StartupGuardEnabled) {
    $script:StartupButton.Text = '取消开机守护'
  } else {
    $script:StartupButton.Text = '启用开机守护'
  }
}

function Set-StartupGuard {
  param([bool]$Enabled)

  $shortcutPath = Get-StartupShortcutPath
  if ($Enabled) {
    $targetPath = Join-Path $script:RootDir 'VSLLM-Launcher.bat'
    if (-not (Test-Path -LiteralPath $targetPath)) {
      Show-ErrorMessage '启用失败' ("找不到启动文件：`r`n{0}" -f $targetPath)
      return
    }

    try {
      $shell = New-Object -ComObject WScript.Shell
      $shortcut = $shell.CreateShortcut($shortcutPath)
      $shortcut.TargetPath = $targetPath
      $shortcut.Arguments = 'watch'
      $shortcut.WorkingDirectory = $script:RootDir
      $shortcut.Description = '开机后启动 VSLLM 签到+任务+抽奖控制台并开始守护'
      $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
      $shortcut.Save()
      Append-Log '已启用开机守护：下次登录 Windows 后会自动打开控制台并开始守护。'
    } catch {
      Show-ErrorMessage '启用失败' ("创建开机启动快捷方式失败：`r`n{0}" -f $_.Exception.Message)
    }
  } else {
    try {
      Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
      Append-Log '已取消开机守护。'
    } catch {
      Show-ErrorMessage '取消失败' ("删除开机启动快捷方式失败：`r`n{0}" -f $_.Exception.Message)
    }
  }

  Update-StartupButton
}

function Toggle-StartupGuard {
  Set-StartupGuard -Enabled (-not (Test-StartupGuardEnabled))
}

function Ensure-DrawHistoryFile {
  $historyDir = Split-Path -Parent $script:DrawHistoryPath
  if (-not (Test-Path -LiteralPath $historyDir)) {
    New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $script:DrawHistoryPath)) {
    New-Item -ItemType File -Path $script:DrawHistoryPath -Force | Out-Null
  }
  return $script:DrawHistoryPath
}

function Get-CheckInHistoryPath {
  return (Join-Path $script:LogDir 'checkin-history.log')
}

function Ensure-CheckInHistoryFile {
  $path = Get-CheckInHistoryPath
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType File -Path $path -Force | Out-Null
  }
  return $path
}

function Open-DrawHistory {
  $historyPath = Ensure-DrawHistoryFile
  Start-Process notepad.exe -ArgumentList ('"{0}"' -f $historyPath)
}

function Count-Lines {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return 0
  }
  try {
    return @((Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)).Count
  } catch {
    return 0
  }
}

function Count-SuccessfulDrawHistory {
  $historyPath = Ensure-DrawHistoryFile
  try {
    return @((Get-Content -LiteralPath $historyPath -Encoding UTF8 -ErrorAction SilentlyContinue) | Where-Object { $_ -match '抽奖日志：本轮第' }).Count
  } catch {
    return 0
  }
}

function Set-HistoryCursorsToEnd {
  $script:DrawHistoryLineCount = Count-Lines (Ensure-DrawHistoryFile)
  $script:CheckInHistoryLineCount = Count-Lines (Ensure-CheckInHistoryFile)
}

function Flush-HistoryFile {
  param(
    [string]$Path,
    [ref]$Cursor
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  try {
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)
    for ($index = [int]$Cursor.Value; $index -lt $lines.Count; $index += 1) {
      if ($lines[$index]) {
        Append-Log ([string]$lines[$index])
      }
    }
    $Cursor.Value = $lines.Count
  } catch {
  }
}

function Flush-HistoryLogs {
  Flush-HistoryFile -Path (Ensure-CheckInHistoryFile) -Cursor ([ref]$script:CheckInHistoryLineCount)
  Flush-HistoryFile -Path (Ensure-DrawHistoryFile) -Cursor ([ref]$script:DrawHistoryLineCount)
}

function Update-HistorySummary {
  if (-not $script:HistorySummaryLabel -or $script:HistorySummaryLabel.IsDisposed) {
    return
  }

  if ($script:HistorySummaryLabel.InvokeRequired) {
    $script:HistorySummaryLabel.BeginInvoke([Action]{
      Update-HistorySummary
    }) | Out-Null
    return
  }

  $historyPath = Ensure-DrawHistoryFile
  $lines = @(Get-Content -LiteralPath $historyPath -Encoding UTF8 -Tail 200 -ErrorAction SilentlyContinue)
  $drawLines = @($lines | Where-Object { $_ -match '抽奖日志' })
  $state = Read-DrawState
  if ($script:BalanceLabel -and -not $script:BalanceLabel.IsDisposed) {
    $script:BalanceLabel.Text = Get-BalanceSummaryText
  }
  $total = if ($state -and $state.totalAttempts -ne $null) {
    [int]$state.totalAttempts
  } else {
    Count-SuccessfulDrawHistory
  }
  $nextText = ''
  if ($state -and $state.nextRunAt) {
    try {
      $nextRunAt = [DateTime]::Parse([string]$state.nextRunAt).ToLocalTime()
      if ($nextRunAt -gt (Get-Date)) {
        $nextText = '；下次约 ' + $nextRunAt.ToString('HH:mm:ss')
      }
    } catch {
    }
  }

  if (-not $drawLines -or $drawLines.Count -eq 0) {
    $script:HistorySummaryLabel.Text = if ($total -gt 0) { "抽奖：累计 $total 次$nextText" } else { '抽奖：暂无记录' }
    return
  }

  $lastLine = [string]$drawLines[-1]
  $lastText = $lastLine
  if ($lastLine -match '抽奖日志：(.+)$') {
    $lastText = $Matches[1]
  }
  $lastText = $lastText -replace '^本轮第\s+\d+\s+次\s*/\s*累计\s+\d+\s+次：', ''
  if ($lastText -match '本轮次数已用完') {
    $lastText = '本轮次数已用完'
  } elseif ($lastText -match '冷却中') {
    $lastText = '冷却中'
  } elseif ($lastText.Length -gt 32) {
    $lastText = $lastText.Substring(0, 29) + '...'
  }

  $summary = if ($total -gt 0) {
    "抽奖：累计 $total 次；最近 $lastText$nextText"
  } else {
    "抽奖：最近 $lastText$nextText"
  }

  if ($summary.Length -gt 72) {
    $summary = $summary.Substring(0, 69) + '...'
  }
  $script:HistorySummaryLabel.Text = $summary
}

function Show-RecentDrawHistory {
  $historyPath = Ensure-DrawHistoryFile
  $lines = @(Get-Content -LiteralPath $historyPath -Encoding UTF8 -Tail 20 -ErrorAction SilentlyContinue | Where-Object { $_ })

  if ($lines.Count -eq 0) {
    Append-Log '抽奖记录：还没有历史记录。点击[签到+任务+翻牌一次]或[开始守护]后会显示在这里。'
    Update-HistorySummary
    return
  }

  Append-Log '最近抽奖记录：'
  foreach ($line in $lines) {
    Append-Log $line
  }
  Set-HistoryCursorsToEnd
  Update-HistorySummary
}

function Get-WatchDelay {
  $minutes = [int]$script:IntervalBox.Value
  return [TimeSpan]::FromMinutes($minutes)
}

function Format-WaitTime {
  param([TimeSpan]$Duration)

  $totalSeconds = [Math]::Max([Math]::Ceiling($Duration.TotalSeconds), 0)
  $hours = [Math]::Floor($totalSeconds / 3600)
  $minutes = [Math]::Floor(($totalSeconds % 3600) / 60)
  $seconds = $totalSeconds % 60
  $parts = @()
  if ($hours -gt 0) {
    $parts += ("{0} 小时" -f $hours)
  }
  if ($minutes -gt 0) {
    $parts += ("{0} 分" -f $minutes)
  }
  if ($seconds -gt 0 -or $parts.Count -eq 0) {
    $parts += ("{0} 秒" -f $seconds)
  }
  return ($parts -join ' ')
}

function Get-DrawStateWatchTime {
  $state = Read-DrawState
  if (-not $state -or -not $state.nextRunAt) {
    return $null
  }

  try {
    $nextRunAt = [DateTime]::Parse([string]$state.nextRunAt).ToLocalTime()
  } catch {
    return $null
  }

  if ($nextRunAt -le (Get-Date)) {
    $nextRunAt = (Get-Date).AddSeconds(10)
  }

  return [PSCustomObject]@{
    NextRunAt = $nextRunAt
    CooldownText = [string]$state.lastCooldownText
    CooldownMs = $state.lastCooldownMs
  }
}

function Schedule-NextWatchCheck {
  if (-not $script:WatchActive) {
    Set-RunningState $false
    return
  }

  $statePlan = Get-DrawStateWatchTime
  if ($statePlan) {
    $script:WatchNextRunAt = $statePlan.NextRunAt
    $waitText = Format-WaitTime ($script:WatchNextRunAt - (Get-Date))
    Append-Log ("守护：按页面冷却时间执行，下一轮约 {0}，等待 {1}。" -f $script:WatchNextRunAt.ToString('yyyy-MM-dd HH:mm:ss'), $waitText)
    if ($statePlan.CooldownText) {
      Append-Log ("守护：冷却提示：{0}" -f $statePlan.CooldownText)
    }
  } else {
    $delay = Get-WatchDelay
    $script:WatchNextRunAt = (Get-Date).Add($delay)
    Append-Log ("守护：未读到冷却倒计时，下一轮约 {0}，等待 {1} 分钟。" -f $script:WatchNextRunAt.ToString('yyyy-MM-dd HH:mm:ss'), [int]$script:IntervalBox.Value)
  }

  if ($script:WatchTimer) {
    $script:WatchTimer.Start()
  }
  Set-RunningState $false
}

function Invoke-WatchCheck {
  if (-not $script:WatchActive) {
    return
  }

  if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
    return
  }

  if ($script:WatchTimer) {
    $script:WatchTimer.Stop()
  }

  $script:WatchNextRunAt = $null
  $script:WatchRound += 1
  Append-Log ("守护：第 {0} 轮开始，执行签到+今日任务+翻牌。" -f $script:WatchRound)
  Invoke-NpmScript 'api' '守护检查'
}

function Start-WatchMode {
  if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
    Append-Log '已有任务正在运行，请先停止或等待结束。'
    return
  }

  if (-not (Test-RuntimeReady)) {
    return
  }

  Show-MainWindow
  Stop-LegacyBackgroundWatch
  Stop-ProjectWatchProcesses
  $script:WatchActive = $true
  $script:WatchRound = 0
  $script:WatchNextRunAt = $null
  Append-Log ("守护已启动：每轮会先签到、执行今日任务，再翻牌；读不到网页冷却时，每 {0} 分钟兜底检查一次。" -f [int]$script:IntervalBox.Value)
  Invoke-WatchCheck
}

function Stop-WatchMode {
  if ($script:WatchActive) {
    Append-Log '守护已停止。'
  }
  $script:WatchActive = $false
  $script:WatchNextRunAt = $null
  if ($script:WatchTimer) {
    $script:WatchTimer.Stop()
  }
}

function Invoke-LauncherAction {
  param(
    [string]$Action,
    [string]$Source = '控制台'
  )

  $actionText = if ([string]::IsNullOrWhiteSpace($Action)) { 'show' } else { $Action.Trim().ToLowerInvariant() }
  switch ($actionText) {
    'show' {
      Show-MainWindow
    }
    'login' {
      Show-MainWindow
      Invoke-VisibleNpmScript 'login:browser' '首次登录'
    }
    'api' {
      Show-MainWindow
      Invoke-NpmScript 'api' '签到+任务+翻牌一次'
    }
    'watch' {
      Show-MainWindow
      Start-WatchMode
    }
    'stop' {
      Stop-AllTasks
      Show-MainWindow
      Append-Log '已执行停止命令。'
    }
    default {
      Show-MainWindow
      Append-Log ("未知启动动作：{0}（来源：{1}）" -f $Action, $Source)
    }
  }
}

function Process-ExternalActionRequest {
  if (-not (Test-Path -LiteralPath $script:ActionRequestPath)) {
    return
  }

  try {
    $request = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ActionRequestPath | ConvertFrom-Json
  } catch {
    return
  }

  $requestId = [string]$request.id
  if (-not $requestId -or $requestId -eq $script:LastActionRequestId) {
    return
  }

  $script:LastActionRequestId = $requestId
  Append-Log ("收到外部启动动作：{0}" -f ([string]$request.action))
  Invoke-LauncherAction -Action ([string]$request.action) -Source '外部入口'
}

function Invoke-StartupAction {
  if ($script:StartupActionConsumed -or -not $script:StartupAction) {
    return
  }

  $script:StartupActionConsumed = $true
  Invoke-LauncherAction -Action $script:StartupAction -Source '启动参数'
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'VSLLM 签到+任务+抽奖控制台'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Size = New-Object System.Drawing.Size(980, 700)
$script:Form.MinimumSize = New-Object System.Drawing.Size(900, 660)
$script:Form.Font = New-Font 9
$script:Form.ShowInTaskbar = $true

$script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('打开控制台')
$loginMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('首次登录')
$apiOnceMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('签到+任务+翻牌一次')
$watchMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('开始守护')
$historyMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('抽奖记录')
$stopMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('停止守护')
$exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem('退出程序')

$openMenuItem.Add_Click({ Show-MainWindow })
$loginMenuItem.Add_Click({ Invoke-VisibleNpmScript 'login:browser' '首次登录' })
$apiOnceMenuItem.Add_Click({
  Show-MainWindow
  Invoke-NpmScript 'api' '签到+任务+翻牌一次'
})
$watchMenuItem.Add_Click({
  Show-MainWindow
  Start-WatchMode
})
$historyMenuItem.Add_Click({
  Show-MainWindow
  Show-RecentDrawHistory
})
$stopMenuItem.Add_Click({ Stop-AllTasks })
$exitMenuItem.Add_Click({ Exit-Launcher })

[void]$script:TrayMenu.Items.Add($openMenuItem)
[void]$script:TrayMenu.Items.Add($loginMenuItem)
[void]$script:TrayMenu.Items.Add($apiOnceMenuItem)
[void]$script:TrayMenu.Items.Add($watchMenuItem)
[void]$script:TrayMenu.Items.Add($historyMenuItem)
[void]$script:TrayMenu.Items.Add($stopMenuItem)
[void]$script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:TrayMenu.Items.Add($exitMenuItem)

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
$script:TrayIcon.Text = 'VSLLM 签到+任务+抽奖控制台'
$script:TrayIcon.ContextMenuStrip = $script:TrayMenu
$script:TrayIcon.Visible = $true
$script:TrayIcon.Add_DoubleClick({ Show-MainWindow })

$script:TaskCheckTimer = New-Object System.Windows.Forms.Timer
$script:TaskCheckTimer.Interval = 1000
$script:TaskCheckTimer.Add_Tick({ Complete-CurrentProcess })

$script:WatchTimer = New-Object System.Windows.Forms.Timer
$script:WatchTimer.Interval = 5000
$script:WatchTimer.Add_Tick({
  if ($script:WatchActive) {
    Set-RunningState $false
  }
  if ($script:WatchActive -and $script:WatchNextRunAt -and (Get-Date) -ge $script:WatchNextRunAt) {
    Invoke-WatchCheck
  }
})

$script:ActionRequestTimer = New-Object System.Windows.Forms.Timer
$script:ActionRequestTimer.Interval = 1000
$script:ActionRequestTimer.Add_Tick({ Process-ExternalActionRequest })
$script:ActionRequestTimer.Start()

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'VSLLM 签到+任务+抽奖控制台'
$titleLabel.Font = New-Font 16 ([System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(18, 16)
$script:Form.Controls.Add($titleLabel)

$tipLabel = New-Object System.Windows.Forms.Label
$tipLabel.Text = '先登录，再点按钮；日志里看结果。'
$tipLabel.AutoSize = $true
$tipLabel.Location = New-Object System.Drawing.Point(20, 52)
$script:Form.Controls.Add($tipLabel)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = '状态：准备就绪'
$script:StatusLabel.AutoSize = $false
$script:StatusLabel.AutoEllipsis = $true
$script:StatusLabel.Location = New-Object System.Drawing.Point(20, 84)
$script:StatusLabel.Size = New-Object System.Drawing.Size(470, 24)
$script:Form.Controls.Add($script:StatusLabel)

$script:BalanceLabel = New-Object System.Windows.Forms.Label
$script:BalanceLabel.Text = '余额：未读取'
$script:BalanceLabel.AutoSize = $false
$script:BalanceLabel.AutoEllipsis = $true
$script:BalanceLabel.Location = New-Object System.Drawing.Point(20, 108)
$script:BalanceLabel.Size = New-Object System.Drawing.Size(920, 24)
$script:BalanceLabel.Anchor = 'Top,Left,Right'
$script:Form.Controls.Add($script:BalanceLabel)

$script:HistorySummaryLabel = New-Object System.Windows.Forms.Label
$script:HistorySummaryLabel.Text = '抽奖记录：暂无'
$script:HistorySummaryLabel.AutoSize = $false
$script:HistorySummaryLabel.AutoEllipsis = $true
$script:HistorySummaryLabel.Location = New-Object System.Drawing.Point(20, 132)
$script:HistorySummaryLabel.Size = New-Object System.Drawing.Size(920, 24)
$script:HistorySummaryLabel.Anchor = 'Top,Left,Right'
$script:Form.Controls.Add($script:HistorySummaryLabel)

$intervalLabel = New-Object System.Windows.Forms.Label
$intervalLabel.Text = '兜底间隔分钟：'
$intervalLabel.AutoSize = $true
$intervalLabel.Location = New-Object System.Drawing.Point(500, 84)
$script:Form.Controls.Add($intervalLabel)

$script:IntervalBox = New-Object System.Windows.Forms.NumericUpDown
$script:IntervalBox.Minimum = 30
$script:IntervalBox.Maximum = 720
$script:IntervalBox.Value = 180
$script:IntervalBox.Location = New-Object System.Drawing.Point(600, 80)
$script:IntervalBox.Size = New-Object System.Drawing.Size(58, 26)
$script:Form.Controls.Add($script:IntervalBox)

$drawLabel = New-Object System.Windows.Forms.Label
$drawLabel.Text = '每轮最多翻牌：'
$drawLabel.AutoSize = $true
$drawLabel.Location = New-Object System.Drawing.Point(690, 84)
$script:Form.Controls.Add($drawLabel)

$script:DrawLimitBox = New-Object System.Windows.Forms.NumericUpDown
$script:DrawLimitBox.Minimum = 0
$script:DrawLimitBox.Maximum = 10
$script:DrawLimitBox.Value = 3
$script:DrawLimitBox.Location = New-Object System.Drawing.Point(790, 80)
$script:DrawLimitBox.Size = New-Object System.Drawing.Size(58, 26)
$script:Form.Controls.Add($script:DrawLimitBox)

$script:DailyTasksCheckBox = New-Object System.Windows.Forms.CheckBox
$script:DailyTasksCheckBox.Text = '自动今日任务'
$script:DailyTasksCheckBox.Checked = $true
$script:DailyTasksCheckBox.AutoSize = $true
$script:DailyTasksCheckBox.Location = New-Object System.Drawing.Point(850, 83)
$script:DailyTasksCheckBox.Anchor = 'Top,Right'
$script:Form.Controls.Add($script:DailyTasksCheckBox)

$buttonY = 168
$buttonW = 142
$buttonH = 42
$gap = 12

$script:LoginButton = New-Object System.Windows.Forms.Button
$script:LoginButton.Text = '首次登录'
$script:LoginButton.Location = New-Object System.Drawing.Point(22, $buttonY)
$script:LoginButton.Size = New-Object System.Drawing.Size($buttonW, $buttonH)
$script:LoginButton.Add_Click({ Invoke-VisibleNpmScript 'login:browser' '首次登录' })
$script:Form.Controls.Add($script:LoginButton)

$script:RunButton = New-Object System.Windows.Forms.Button
$script:RunButton.Text = '签到+任务+翻牌一次'
$script:RunButton.Location = New-Object System.Drawing.Point((22 + ($buttonW + $gap)), $buttonY)
$script:RunButton.Size = New-Object System.Drawing.Size($buttonW, $buttonH)
$script:RunButton.Add_Click({ Invoke-NpmScript 'api' '签到+任务+翻牌一次' })
$script:Form.Controls.Add($script:RunButton)

$script:WatchButton = New-Object System.Windows.Forms.Button
$script:WatchButton.Text = '开始守护'
$script:WatchButton.Location = New-Object System.Drawing.Point((22 + 2 * ($buttonW + $gap)), $buttonY)
$script:WatchButton.Size = New-Object System.Drawing.Size($buttonW, $buttonH)
$script:WatchButton.Add_Click({ Start-WatchMode })
$script:Form.Controls.Add($script:WatchButton)

$script:StopButton = New-Object System.Windows.Forms.Button
$script:StopButton.Text = '停止守护'
$script:StopButton.Enabled = $false
$script:StopButton.Location = New-Object System.Drawing.Point((22 + 3 * ($buttonW + $gap)), $buttonY)
$script:StopButton.Size = New-Object System.Drawing.Size($buttonW, $buttonH)
$script:StopButton.Add_Click({ Stop-AllTasks })
$script:Form.Controls.Add($script:StopButton)

$script:RefreshBalanceButton = New-Object System.Windows.Forms.Button
$script:RefreshBalanceButton.Text = '刷新余额'
$script:RefreshBalanceButton.Location = New-Object System.Drawing.Point((22 + 4 * ($buttonW + $gap)), $buttonY)
$script:RefreshBalanceButton.Size = New-Object System.Drawing.Size(112, $buttonH)
$script:RefreshBalanceButton.Add_Click({ Invoke-NpmScript 'api:balance' '刷新余额' })
$script:Form.Controls.Add($script:RefreshBalanceButton)

$smallY = 224
$smallW = 120
$smallGap = 10

$openLogButton = New-Object System.Windows.Forms.Button
$openLogButton.Text = '打开日志目录'
$openLogButton.Location = New-Object System.Drawing.Point(22, $smallY)
$openLogButton.Size = New-Object System.Drawing.Size($smallW, 34)
$openLogButton.Add_Click({ Open-Folder (Join-Path $script:RootDir 'logs') })
$script:Form.Controls.Add($openLogButton)

$openDrawHistoryButton = New-Object System.Windows.Forms.Button
$openDrawHistoryButton.Text = '抽奖记录'
$openDrawHistoryButton.Location = New-Object System.Drawing.Point((22 + 1 * ($smallW + $smallGap)), $smallY)
$openDrawHistoryButton.Size = New-Object System.Drawing.Size($smallW, 34)
$openDrawHistoryButton.Add_Click({ Show-RecentDrawHistory })
$script:Form.Controls.Add($openDrawHistoryButton)

$openHistoryFileButton = New-Object System.Windows.Forms.Button
$openHistoryFileButton.Text = '打开记录文件'
$openHistoryFileButton.Location = New-Object System.Drawing.Point((22 + 2 * ($smallW + $smallGap)), $smallY)
$openHistoryFileButton.Size = New-Object System.Drawing.Size($smallW, 34)
$openHistoryFileButton.Add_Click({ Open-DrawHistory })
$script:Form.Controls.Add($openHistoryFileButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = '清空窗口日志'
$clearButton.Location = New-Object System.Drawing.Point((22 + 3 * ($smallW + $smallGap)), $smallY)
$clearButton.Size = New-Object System.Drawing.Size($smallW, 34)
$clearButton.Add_Click({
  $script:OutputBox.Clear()
  Append-Log '窗口日志已清空。历史抽奖记录不会删除。'
})
$script:Form.Controls.Add($clearButton)

$cleanLogsButton = New-Object System.Windows.Forms.Button
$cleanLogsButton.Text = '清理旧日志'
$cleanLogsButton.Location = New-Object System.Drawing.Point((22 + 4 * ($smallW + $smallGap)), $smallY)
$cleanLogsButton.Size = New-Object System.Drawing.Size($smallW, 34)
$cleanLogsButton.Add_Click({ Clear-RuntimeLogs })
$script:Form.Controls.Add($cleanLogsButton)

$script:StartupButton = New-Object System.Windows.Forms.Button
$script:StartupButton.Text = '启用开机守护'
$script:StartupButton.Location = New-Object System.Drawing.Point((22 + 5 * ($smallW + $smallGap)), $smallY)
$script:StartupButton.Size = New-Object System.Drawing.Size($smallW, 34)
$script:StartupButton.Add_Click({ Toggle-StartupGuard })
$script:Form.Controls.Add($script:StartupButton)

$openRootButton = New-Object System.Windows.Forms.Button
$openRootButton.Text = '打开目录'
$openRootButton.Location = New-Object System.Drawing.Point((22 + 6 * ($smallW + $smallGap)), $smallY)
$openRootButton.Size = New-Object System.Drawing.Size($smallW, 34)
$openRootButton.Add_Click({ Open-Folder $script:RootDir })
$script:Form.Controls.Add($openRootButton)

$script:OutputBox = New-Object System.Windows.Forms.TextBox
$script:OutputBox.Multiline = $true
$script:OutputBox.ReadOnly = $true
$script:OutputBox.ScrollBars = 'Vertical'
$script:OutputBox.WordWrap = $false
$script:OutputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:OutputBox.Anchor = 'Top,Bottom,Left,Right'
$script:OutputBox.Location = New-Object System.Drawing.Point(22, 276)
$script:OutputBox.Size = New-Object System.Drawing.Size(920, 356)
$script:Form.Controls.Add($script:OutputBox)

$script:Form.Add_Shown({
  Show-MainWindow
  Update-HistorySummary
  Update-StartupButton
  Invoke-StartupAction
})

$script:Form.Add_Resize({
  if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
    Hide-ToTray
  }
})

$script:Form.Add_FormClosing({
  if (-not $script:ReallyExit) {
    $_.Cancel = $true
    Hide-ToTray
    return
  }

  if ($script:TrayIcon) {
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    $script:TrayIcon = $null
  }

  Release-SingleInstance
})

Set-RunningState $false
Append-Log ("项目目录：{0}" -f $script:RootDir)
Append-Log '准备就绪。'
Show-RecentDrawHistory
Set-HistoryCursorsToEnd
[void][System.Windows.Forms.Application]::Run($script:Form)

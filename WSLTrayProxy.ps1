# AI-assisted: initial implementation created with OpenAI Codex.
# Review the code before using it in your environment.

param(
  [string]$Distro = "Debian",
  [int]$PollSeconds = 3
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$appDir = Join-Path $env:LOCALAPPDATA "WSLTrayProxy"
$logFile = Join-Path $appDir "proxy.log"
New-Item -ItemType Directory -Path $appDir -Force | Out-Null

function Write-ProxyLog([string]$Message) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Add-Content -Path $logFile -Encoding utf8
}

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, "Local\WSLTrayProxy-$Distro", [ref]$createdNew)
if (-not $createdNew) {
  $mutex.Dispose()
  exit 0
}

$wslExe = Join-Path $env:WINDIR "System32\wsl.exe"
$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$Distro"
$shell = New-Object -ComObject WScript.Shell
$appIcons = @{}
$updating = $false
$disposed = $false

function Invoke-ProcessCapture([string]$FileName, [string[]]$Arguments) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FileName
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  foreach ($argument in $Arguments) {
    $null = $psi.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::Start($psi)
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit(5000) | Out-Null
  if (-not $process.HasExited) {
    $process.Kill()
    throw "Process timed out: $FileName"
  }
  if ($process.ExitCode -ne 0) {
    throw "Process failed ($($process.ExitCode)): $stderr"
  }
  return $stdout
}

function Get-RegisteredApps {
  $apps = @{}
  if (-not (Test-Path $startMenuDir)) {
    return $apps
  }

  foreach ($file in Get-ChildItem -LiteralPath $startMenuDir -Filter "*.lnk" -File) {
    try {
      $shortcut = $shell.CreateShortcut($file.FullName)
      if ($shortcut.TargetPath -notmatch "(?i)\\wslg?\.exe$") {
        continue
      }
      $match = [regex]::Match($shortcut.Arguments, '(?:^|\s)--\s+(?:"([^"]+)"|(\S+))')
      if (-not $match.Success) {
        continue
      }
      $executable = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
      $processName = [IO.Path]::GetFileName($executable).ToLowerInvariant()
      if (-not $processName) {
        continue
      }
      $name = $file.BaseName -replace " \($([regex]::Escape($Distro))\)$", ""
      $iconPath = ($shortcut.IconLocation -replace ',\s*-?\d+$', '')
      $apps[$processName] = [pscustomobject]@{
        Key = $processName
        Name = $name
        Executable = $executable
        ShortcutPath = $file.FullName
        IconPath = $iconPath
      }
    }
    catch {
      Write-ProxyLog "Skipping shortcut $($file.FullName): $($_.Exception.Message)"
    }
  }
  return $apps
}

function Get-LinuxProcesses {
  $result = @()
  $output = Invoke-ProcessCapture $wslExe @("-d", $Distro, "--", "ps", "-eo", "pid=,args=")
  foreach ($line in $output -split "`r?`n") {
    $match = [regex]::Match($line, '^\s*(\d+)\s+(.+)$')
    if (-not $match.Success) {
      continue
    }
    $arguments = $match.Groups[2].Value.Trim()
    $firstTokenMatch = [regex]::Match($arguments, '^(?:"([^"]+)"|(\S+))')
    if (-not $firstTokenMatch.Success) {
      continue
    }
    $firstToken = if ($firstTokenMatch.Groups[1].Success) { $firstTokenMatch.Groups[1].Value } else { $firstTokenMatch.Groups[2].Value }
    $result += [pscustomobject]@{
      Pid = [int]$match.Groups[1].Value
      ProcessName = [IO.Path]::GetFileName($firstToken).ToLowerInvariant()
      Arguments = $arguments
    }
  }
  return $result
}

function Get-AppIcon([string]$Path) {
  try {
    if ($Path -and (Test-Path -LiteralPath $Path)) {
      return [Drawing.Icon]::new($Path)
    }
  }
  catch {
    Write-ProxyLog "Unable to load icon ${Path}: $($_.Exception.Message)"
  }
  return [Drawing.SystemIcons]::Application.Clone()
}

function Get-ControlIcon {
  try {
    $icon = [Drawing.Icon]::ExtractAssociatedIcon($wslExe)
    if ($icon) {
      return $icon.Clone()
    }
  }
  catch {
    Write-ProxyLog "Unable to load WSL icon: $($_.Exception.Message)"
  }
  return [Drawing.SystemIcons]::Application.Clone()
}

function Stop-LinuxProcess([int]$ProcessId) {
  try {
    $null = Invoke-ProcessCapture $wslExe @("-d", $Distro, "--", "kill", "-TERM", "$ProcessId")
    Write-ProxyLog "Sent TERM to PID $ProcessId"
  }
  catch {
    [Windows.Forms.MessageBox]::Show(
      "Не удалось завершить Linux-процесс $ProcessId.`n$($_.Exception.Message)",
      "WSL Tray Proxy",
      [Windows.Forms.MessageBoxButtons]::OK,
      [Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  }
}

function Open-Shortcut([string]$Path) {
  try {
    Start-Process -FilePath $Path | Out-Null
  }
  catch {
    Write-ProxyLog "Unable to launch ${Path}: $($_.Exception.Message)"
  }
}

function Remove-AppIcon([string]$Key) {
  if (-not $appIcons.ContainsKey($Key)) {
    return
  }
  $entry = $appIcons[$Key]
  $entry.NotifyIcon.Visible = $false
  $entry.NotifyIcon.Dispose()
  $entry.Icon.Dispose()
  $appIcons.Remove($Key)
  Write-ProxyLog "Removed tray icon: $Key"
}

function Add-AppIcon($App, [int]$ProcessId) {
  $icon = Get-AppIcon $App.IconPath
  $notify = [Windows.Forms.NotifyIcon]::new()
  $notify.Icon = $icon
  $notify.Text = ("{0} ({1}) PID {2}" -f $App.Name, $Distro, $ProcessId).Substring(0, [Math]::Min(63, ("{0} ({1}) PID {2}" -f $App.Name, $Distro, $ProcessId).Length))

  $menu = [Windows.Forms.ContextMenuStrip]::new()
  $title = $menu.Items.Add("$($App.Name) — PID $ProcessId")
  $title.Enabled = $false
  $null = $menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
  $openItem = $menu.Items.Add("Открыть / активировать")
  $quitItem = $menu.Items.Add("Завершить в Linux")
  $null = $menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
  $proxyExitItem = $menu.Items.Add("Остановить WSL Tray Proxy")

  $shortcutPath = $App.ShortcutPath
  $openAction = { Open-Shortcut $shortcutPath }.GetNewClosure()
  $pidToStop = $ProcessId
  $quitAction = { Stop-LinuxProcess $pidToStop }.GetNewClosure()
  $openItem.add_Click($openAction)
  $notify.add_DoubleClick($openAction)
  $quitItem.add_Click($quitAction)
  $proxyExitItem.add_Click({ Stop-Proxy })

  $notify.ContextMenuStrip = $menu
  $notify.Visible = $true
  $appIcons[$App.Key] = [pscustomobject]@{
    NotifyIcon = $notify
    Icon = $icon
    Pid = $ProcessId
    App = $App
  }
  Write-ProxyLog "Added tray icon: $($App.Name), PID $ProcessId"
}

function Update-Tray {
  if ($updating -or $disposed) {
    return
  }
  $script:updating = $true
  try {
    $registered = Get-RegisteredApps
    $processes = Get-LinuxProcesses
    $running = @{}

    foreach ($key in $registered.Keys) {
      $matches = @($processes | Where-Object {
        $_.ProcessName -eq $key -and $_.Arguments -notmatch '\s--type='
      } | Sort-Object Pid)
      if ($matches.Count -gt 0) {
        $running[$key] = [pscustomobject]@{
          App = $registered[$key]
          Pid = $matches[0].Pid
        }
      }
    }

    foreach ($key in @($appIcons.Keys)) {
      if (-not $running.ContainsKey($key) -or $appIcons[$key].Pid -ne $running[$key].Pid) {
        Remove-AppIcon $key
      }
    }
    foreach ($key in $running.Keys) {
      if (-not $appIcons.ContainsKey($key)) {
        Add-AppIcon $running[$key].App $running[$key].Pid
      }
    }
    $controlNotify.Text = "WSL Tray Proxy — $($appIcons.Count) приложений"
    $statusItem.Text = "Запущено приложений: $($appIcons.Count)"
  }
  catch {
    Write-ProxyLog "Update failed: $($_.Exception.Message)"
    $controlNotify.Text = "WSL Tray Proxy — ошибка"
  }
  finally {
    $script:updating = $false
  }
}

function Stop-Proxy {
  if ($disposed) {
    return
  }
  $script:disposed = $true
  $timer.Stop()
  foreach ($key in @($appIcons.Keys)) {
    Remove-AppIcon $key
  }
  $controlNotify.Visible = $false
  $controlNotify.Dispose()
  $controlIcon.Dispose()
  Write-ProxyLog "Proxy stopped"
  $mutex.ReleaseMutex() | Out-Null
  $mutex.Dispose()
  [Windows.Forms.Application]::Exit()
}

$controlIcon = Get-ControlIcon
$controlNotify = [Windows.Forms.NotifyIcon]::new()
$controlNotify.Icon = $controlIcon
$controlNotify.Text = "WSL Tray Proxy"
$controlMenu = [Windows.Forms.ContextMenuStrip]::new()
$statusItem = $controlMenu.Items.Add("Запущено приложений: 0")
$statusItem.Enabled = $false
$null = $controlMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$refreshItem = $controlMenu.Items.Add("Обновить сейчас")
$openFolderItem = $controlMenu.Items.Add("Открыть ярлыки Debian")
$null = $controlMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$exitItem = $controlMenu.Items.Add("Выход")
$refreshItem.add_Click({ Update-Tray })
$openFolderItem.add_Click({ Start-Process explorer.exe -ArgumentList $startMenuDir })
$exitItem.add_Click({ Stop-Proxy })
$controlNotify.ContextMenuStrip = $controlMenu
$controlNotify.Visible = $true

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = [Math]::Max(1, $PollSeconds) * 1000
$timer.add_Tick({ Update-Tray })
$timer.Start()

Write-ProxyLog "Proxy started for distro $Distro"
Update-Tray
[Windows.Forms.Application]::Run()

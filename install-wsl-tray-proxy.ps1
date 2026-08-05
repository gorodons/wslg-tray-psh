# AI-assisted: initial implementation created with OpenAI Codex.
# Review the code before using it in your environment.

$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "WSLTrayProxy.ps1"
$installDir = Join-Path $env:LOCALAPPDATA "WSLTrayProxy"
$installedScript = Join-Path $installDir "WSLTrayProxy.ps1"
$startupDir = [Environment]::GetFolderPath("Startup")
$programsDir = [Environment]::GetFolderPath("Programs")
$startupShortcutPath = Join-Path $startupDir "WSL Tray Proxy.lnk"
$startMenuShortcutPath = Join-Path $programsDir "WSL Tray Proxy.lnk"
$pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
$iconLocation = "$env:WINDIR\System32\wsl.exe,0"

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $installedScript -Force

$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in @($startupShortcutPath, $startMenuShortcutPath)) {
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $pwsh
  $shortcut.Arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installedScript`" -Distro Debian"
  $shortcut.WorkingDirectory = $installDir
  $shortcut.IconLocation = $iconLocation
  $shortcut.WindowStyle = 7
  $shortcut.Description = "Show running Debian WSLg applications in the Windows notification area"
  $shortcut.Save()
}

Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
  Where-Object { $_.CommandLine -like "*WSLTrayProxy.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Start-Process -FilePath $pwsh -ArgumentList @(
  "-NoLogo",
  "-NoProfile",
  "-STA",
  "-WindowStyle", "Hidden",
  "-ExecutionPolicy", "Bypass",
  "-File", $installedScript,
  "-Distro", "Debian"
) -WindowStyle Hidden

Write-Output "Installed: $installedScript"
Write-Output "Startup: $startupShortcutPath"
Write-Output "Start menu: $startMenuShortcutPath"

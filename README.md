# WSLg Tray Proxy (PowerShell)

> **AI-assisted project:** the initial implementation and documentation were created with OpenAI Codex. Review the code before using it in your environment.

`WSLg Tray Proxy` mirrors running WSLg applications into the Windows notification area.

For every running Linux GUI application registered by WSLg in the Windows Start menu, the proxy creates a Windows tray icon with actions to:

- open or activate the application;
- send `SIGTERM` to its main Linux process;
- stop the tray proxy.

The proxy also adds a permanent control icon showing the number of detected applications. It refreshes the process list every three seconds.

## Requirements

- Windows 10 or 11 with WSLg;
- PowerShell 7 installed at `C:\Program Files\PowerShell\7\pwsh.exe`;
- a WSL distribution with GUI applications registered in `Start menu → <distribution>`.

The default distribution is `Debian`.

## Install

Open PowerShell 7 in this directory and run:

```powershell
./install-wsl-tray-proxy.ps1
```

The installer copies the proxy to:

```text
%LOCALAPPDATA%\WSLTrayProxy\WSLTrayProxy.ps1
```

and creates shortcuts for autostart and manual launch from Start:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\WSL Tray Proxy.lnk
%APPDATA%\Microsoft\Windows\Start Menu\Programs\WSL Tray Proxy.lnk
```

Both shortcuts use the system WSL icon. The proxy control icon in the notification
area uses the same icon. The installer then starts the proxy immediately. A named
mutex prevents duplicate instances.

## Run manually

```powershell
& "C:\Program Files\PowerShell\7\pwsh.exe" `
  -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\WSLTrayProxy\WSLTrayProxy.ps1" `
  -Distro Debian
```

To use another distribution, replace `Debian` with its exact `wsl.exe -l -q` name.

## Logs

```text
%LOCALAPPDATA%\WSLTrayProxy\proxy.log
```

## Remove

Exit the proxy from its control icon, then remove:

```powershell
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\WSL Tray Proxy.lnk" -ErrorAction SilentlyContinue
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\WSL Tray Proxy.lnk" -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\WSLTrayProxy" -Recurse -Force
```

## Limitations

- The proxy detects applications for which WSLg has generated a Start menu shortcut.
- It provides Windows-side launch and process controls; it does not bridge an application's native Linux StatusNotifierItem/XEmbed menu.
- “Open / activate” launches the WSLg shortcut. Applications without single-instance behavior may open another window.

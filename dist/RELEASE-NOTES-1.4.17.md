# TBFDesk 1.4.17 (Windows client) — 2026-10-29

Fixes a release-build-only bug in 1.4.16 that left the main window half-working.

## Fixed
- **The "⋮" menu in the main window did nothing**, and the main window stayed on
  **"ID: Generating ..." / "Connecting to the TBFDesk network ..."** even with the server
  reachable. Cause: the release (inline) build packs every UI script into one script block;
  the main-window script had outgrown Sciter's per-block limit, so everything after a point
  failed to load ("Bad parse code") — the menu handler and the 1-second status polling among
  it. Each script now loads in its own block. Reinstalling 1.4.16 does not help; 1.4.17 does.
- Roaming profiles (redirected `%APPDATA%`) were not the cause; the fix applies to every
  install.
- Garbled characters in the Windows build ("Einstellungen â€¦", "â–¾" on the language
  drop-down): the build step read the UI scripts in the Windows code page instead of UTF-8.

## Diagnostics
- Sciter script errors are now written to the log file
  (`%APPDATA%\TBFDesk\log\…`). Before, a script failure left no trace anywhere.
- Debug run with live output in the shell:
  ```powershell
  Get-Service TBFDesk | Stop-Service        # optional: lets the UI own the config
  $env:RUST_LOG = 'debug'
  Start-Process 'C:\Program Files\TBFDesk\TBFDesk.exe' -NoNewWindow -Wait
  ```
  The log streams into that PowerShell window as well as into the log file.

## Install / upgrade
Run `tbfdesk-1.4.17-x64-install.exe` (double-click, or `--silent-install` from an
elevated prompt). It upgrades 1.4.x in place and keeps the machine's ID, device key and
settings. Service name `TBFDesk`, installed to `C:\Program Files\TBFDesk`, starts
automatically at boot.

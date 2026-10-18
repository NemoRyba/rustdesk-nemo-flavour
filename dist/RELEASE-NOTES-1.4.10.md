# TBFDesk 1.4.10 — Windows x64

Two downloads with the same content; use whichever fits:

| file | use |
|---|---|
| `tbfdesk-1.4.10-x64-install.exe` | single file: double-click, or `--silent-install` for GPO/RMM |
| `TBFDesk-Windows-Client.zip` | for the one-line install/update script (below) |

sha256 of the installer: `741f979e8fd34c26739fe4d47a3cb17170f72f0908905540071cb612ef27fdf9`

Not code-signed: SmartScreen → **More info → Run anyway**.

## One-line install / update
Run this in an elevated PowerShell. It installs a new machine, or upgrades an existing one in
place and keeps its identity (ID, password, device key, settings):
```powershell
$u='https://github.com/NemoRyba/rustdesk-client-nemo/releases/latest/download/TBFDesk-Windows-Client.zip'
$d="$env:TEMP\tbfdesk"; Remove-Item $d -Recurse -Force -EA 0; New-Item -ItemType Directory $d | Out-Null
Invoke-WebRequest $u -OutFile "$d\c.zip"; Expand-Archive "$d\c.zip" $d -Force
Start-Process "$d\rustdesk.exe" -ArgumentList '--silent-install' -Verb RunAs
```

## New: multiple monitors
The session toolbar has a display-mode control with two groups:

| mode | what you get |
|---|---|
| **One display** | the classic view, one remote screen in the window |
| **All in window** | every remote screen side by side in one window |
| **Span my monitors** | one window across all your monitors, each remote screen on its own monitor |
| **Window per display** | one full-screen window per remote screen, each on its own monitor |

Mouse and keyboard follow the window you work in, as if the screens were local.
With three or more remote screens, the **N/M** picker selects which to show. It is
remembered per machine. The two multi-monitor modes are greyed out on a single-monitor PC.

## New: direct connections explain themselves
- ⋮ → **Copy recent log** puts the main and session log on the clipboard, with passwords and
  tokens removed, ready to paste into a support chat. **Open log folder** opens the folder.
- When **Direkt verbinden** fails, the log says why: *connection refused* (nothing behind
  the forward, or a router rejecting it), *timed out* (dropped by a firewall), *a different
  service answered* (the forward points at the wrong host or port), or *no endpoint*, with
  the reason. A relay-only setting ("Always connect via relay", "Use WebSocket", a proxy) is
  named instead of silently skipping the direct path.
- **Direkt verbinden** never ends on the relay. A failure shows the reason and stops; there
  is no automatic retry.

## Also
- "Ready" and "Registered" no longer run together.
- Signed out on a server that does not require login: an **Anmelden** button in the account
  bar, and a sign-in prompt in the empty address book.
- Ctrl+Alt+End sends Ctrl+Alt+Del to a Windows remote. Windows reserves the real
  Ctrl+Alt+Del for itself, so a Windows controller cannot capture it.

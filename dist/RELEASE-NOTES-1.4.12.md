# TBFDesk 1.4.12 — Windows x64

Two downloads with the same content; use whichever fits:

| file | use |
|---|---|
| `tbfdesk-1.4.12-x64-install.exe` | single file: double-click, or `--silent-install` for GPO/RMM |
| `TBFDesk-Windows-Client.zip` | for the one-line install/update script (below) |

sha256 of the installer: `fffd00359bd2f87464dae3223ca83a9652a7e81c85e6871257192d3088dea36b`

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

## New in 1.4.12
- **See who is reachable directly.** Every peer with a published direct endpoint has a
  green **⚡ Direkt** chip in the address book and the recent-sessions list, in tile and list
  view. The chips update as soon as the server publishes or withdraws an endpoint. Type an
  ID into the box and, if it can be reached directly, the endpoint shows underneath.
- **Connect via relay on demand.** The peer's menu has **Über Relay-Server verbinden**
  next to **Direkt verbinden**. It applies to that one connection, unlike "Immer über
  Relay-Server verbinden", which sticks.
- **Privacy mode removed.** On Windows it needs a driver plugin that is not shipped, so it
  only ever showed an error.

## New in 1.4.11: direct sessions show up on the server
A direct session never passes the server, so until now the dashboard had no record of it.
From 1.4.11 the connecting client sends one small report per connection attempt: the target,
the endpoint, whether it worked, how long it took, and on failure why. Nothing is sent during
a session. The dashboard shows the session in **Connections** as **direct-endpoint**, or
**direct-failed** with the reason in the log. The controlled machine also says how a session
reached it (direct / relay / punch).

Needs the server from 2026-10-19 (`139cc6e`, already live). Update both ends: the
connecting side sends the report, the connected side adds the path.

## Everything from 1.4.10
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

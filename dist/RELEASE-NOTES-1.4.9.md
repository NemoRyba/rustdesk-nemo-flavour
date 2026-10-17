# TBFDesk 1.4.9 — Windows x64

Two downloads with the same content — use whichever fits:

| file | use |
|---|---|
| `tbfdesk-1.4.9-x64-install.exe` | single file: double-click, or `--silent-install` for GPO/RMM |
| `TBFDesk-Windows-Client.zip` | for the one-line install/update script (below) |

Not code-signed: SmartScreen → **More info → Run anyway**.

## One-line install / update
Elevated PowerShell; installs a new machine or upgrades an existing one in place, keeping its
identity (ID, password, device key, settings):
```powershell
$u='https://github.com/NemoRyba/rustdesk-client-nemo/releases/latest/download/TBFDesk-Windows-Client.zip'
$d="$env:TEMP\tbfdesk"; Remove-Item $d -Recurse -Force -EA 0; New-Item -ItemType Directory $d | Out-Null
Invoke-WebRequest $u -OutFile "$d\c.zip"; Expand-Archive "$d\c.zip" $d -Force
Start-Process "$d\rustdesk.exe" -ArgumentList '--silent-install' -Verb RunAs
```
It installs to `C:\Program Files\TBFDesk` as `TBFDesk.exe` (service `TBFDesk`), exactly like the
single-file installer. A new machine then needs the setup string: **Import setup string or device key**.

## New: is this machine actually registered?
"Ready" only says the server is answering. Next to it the client now says what that means:

| badge | meaning |
|---|---|
| **Registered** (green) | the server verified this machine's device key and registered its ID — other devices can connect to it |
| **Not registered** (orange) | connected, but the server has not accepted this ID (yet) |
| **No device key** (orange) | registered without a device key — the server is not enforcing device keys |

Hover the word for the explanation.

## Known issue
With `require-device-key` on, the client's NAT-type probe is refused (it does not do the
device-key handshake), so NAT type reads `UNKNOWN_NAT` and peers do not attempt hole punching.
Configured direct endpoints are not affected. Each client start logs one
`Refusing …: require-device-key is on and this client presented no valid device key` on the
server — that line is the probe, **not** the device being refused. See
`HANDOFF-148-UPGRADE-RENDEZVOUS.md`.

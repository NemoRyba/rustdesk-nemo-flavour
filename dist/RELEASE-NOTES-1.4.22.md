# TBFDesk 1.4.22 — Linux (Sciter) hotfix — 2026-11-17

Server unchanged: **1.1.17**. Client commit `43c968114` (branch `nemo-tdd-flutter`); the binary
shows build id `43c968114 2026-11-17 Sciter`.

## Files
| | Sciter |
|---|---|
| Ubuntu 26.04, offline | `tbfdesk-1.4.22-ubuntu26.04-install.run` |
| Ubuntu 24.04, offline | `tbfdesk-1.4.22-ubuntu24.04-install.run` |
| Debian/Ubuntu package | `tbfdesk-1.4.22-amd64.deb` |

Every file has a `.sha256`, plus `SHA256SUMS`. Not code-signed.
Installs **over** 1.4.21 and keeps the configuration, ID and device key:
`sudo apt install ./tbfdesk-1.4.22-amd64.deb` (or run the offline `.run` for your Ubuntu release).

## Fixed
- **"Verbinden" / "Datei übertragen" stayed greyed out** on a machine whose TBFDesk window was
  opened before the administrator allowed the device. The window took the button state from
  the outbound policy only when it was drawn and never redrew when the policy changed, so an
  allowed device kept dead buttons until the whole app was restarted (and a blocked device kept
  live ones). The window now redraws as soon as the policy changes, and says why the buttons
  are disabled ("Ausgehende Verbindungen sind durch die TBF-Richtlinie deaktiviert").

## Verified (Ubuntu 26.04, lab server)
- `apt install` over a provisioned 1.4.21: config, ID and device key byte-identical afterwards,
  device registered again, policy polling.
- Same window, no restart: block -> buttons greyed with the reason; allow -> buttons enabled again.
- Connect opens a session window and reaches the server.

## Not in this release
- **Windows (Sciter)** has the same bug; the fix is in the source and ships with the next Windows
  build. Until then: if the buttons are grey on an allowed machine, quit TBFDesk completely
  (tray icon too) and start it again.
- **Flutter** is not affected (it checks the policy when you click, not when it draws).
- Arch / generic tarball / Android: unchanged, use release-2026-11-12.

## Workaround for 1.4.21 without updating
Quit TBFDesk completely and start it again: `killall -u "$USER" rustdesk; sleep 2; rustdesk &`

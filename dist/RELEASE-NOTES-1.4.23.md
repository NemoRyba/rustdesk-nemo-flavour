# TBFDesk 1.4.23 — Linux (Sciter + Flutter) — 2026-11-17

Client commit `e557c778b` (branch `nemo-tdd-flutter`); the window shows build `e557c778b 2026-11-17`.
Server unchanged (1.1.18 / 1.1.17 both work).

## Files
| | Sciter | Flutter |
|---|---|---|
| Ubuntu 26.04, offline | `tbfdesk-1.4.23-ubuntu26.04-install.run` | `tbfdesk-flutter-1.4.23-ubuntu26.04-install.run` |
| Ubuntu 24.04, offline | `tbfdesk-1.4.23-ubuntu24.04-install.run` | `tbfdesk-flutter-1.4.23-ubuntu24.04-install.run` |
| Debian/Ubuntu package | `tbfdesk-1.4.23-amd64.deb` | `tbfdesk-flutter-1.4.23-amd64.deb` |

Every file has a `.sha256`, plus `SHA256SUMS`. Installs over 1.4.21 / 1.4.22 and keeps
configuration, ID and device key: `sudo apt install ./tbfdesk-1.4.23-amd64.deb`.

**After installing, close the TBFDesk window (and its tray icon) and open it again.** A window
left open across the update keeps running the old program, whose file the update replaced, so
"Verbinden" opens nothing until the window is restarted (`killall -u "$USER" rustdesk; rustdesk &`).

## Fixed
- **Linux: "Verbinden" stayed disabled ("Ausgehende Verbindungen sind durch die TBF-Richtlinie
  deaktiviert") although the device was allowed and the dashboard showed the current policy
  applied.** A server-policy value (outgoing connections off, from a time the device was not
  yet allowed) had been saved into the local settings file, where no later policy could
  remove it. The client now never stores such policy-only values as settings, and **removes
  any already stored copy by itself** on start and on every policy update — affected machines
  heal after installing 1.4.23, nothing to edit by hand.
- **The window now says why the server's policy is not applied**, instead of silently keeping
  an old one: e.g. "the clock of this computer is 60 min ahead of the server — turn on automatic
  date and time", the server not reachable / refusing this computer, or a key mismatch.
  Sciter and Flutter (desktop and Android connect page).

## Verified
Ubuntu 26.04 desktop VM (GNOME, Wayland, root service + user session, like the field machine):
the stuck state reproduced on 1.4.22 (allowed device, buttons disabled); `apt install` of 1.4.23
healed it without any manual step; Connect works; the clock message appears when the clock is
an hour off and disappears when it is corrected.

## Not in this release
- Windows installers: the same fix is in the shared code; Windows builds follow.
- Android: unchanged (release-2026-11-12).

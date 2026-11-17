# TBFDesk 1.4.24 — Linux (Sciter) — 2026-11-17

Client commit `ea7e32da8` (branch `nemo-tdd-flutter`); the window shows build `ea7e32da8 2026-11-17`.
Server unchanged (1.1.18 works; 1.1.19 adds the configurable clock tolerance, which this client uses).

## Files
| | Sciter |
|---|---|
| Ubuntu 26.04, offline | `tbfdesk-1.4.24-ubuntu26.04-install.run` |
| Ubuntu 24.04, offline | `tbfdesk-1.4.24-ubuntu24.04-install.run` |
| Debian/Ubuntu package | `tbfdesk-1.4.24-amd64.deb` |

Every file has a `.sha256`, plus `SHA256SUMS`. Installs over 1.4.21 – 1.4.23 and keeps
configuration, ID and device key: `sudo ./tbfdesk-1.4.24-ubuntu26.04-install.run` or
`sudo apt install ./tbfdesk-1.4.24-amd64.deb`.

**After installing, close the TBFDesk window (and its tray icon) and open it again** — a window
left open across the update keeps running the old program.

## Fixed (Ubuntu 26.04 / every Wayland desktop)
- **Keyboard did not work in a remote session** (typing into the remote computer did nothing,
  in every keyboard mode, also after reconnecting). TBFDesk reads the keyboard through X11, but
  its windows ran as native Wayland windows, whose keys never reach X11. The TBFDesk windows
  now run under XWayland on a Wayland desktop (`TBFDESK_NATIVE_WAYLAND=1` keeps native Wayland).
- **Only one screen could be shared from Ubuntu**, and the screen-sharing question came on
  every connection. A check still looked for the old program name, so TBFDesk always used a
  fallback that allows only one screen and remembers nothing. Now GNOME's "Share Screen" dialog
  lets the user pick **all** monitors and **remembers the choice** ("Remember this selection"),
  so later connections start without the question — which also avoids the session dropping
  when the question was not answered quickly. Settings → General → **"Clear Wayland screen
  selection"** forgets the choice (as in the Flutter client).
- **The session window could not be dragged to another monitor** (or at all). Dragging the
  header now moves it like any other window, across monitors; double-click maximizes/restores.

## Verified (Ubuntu 26.04 desktop VM, GNOME Wayland, two monitors, as a user)
- Keyboard: typed into a remote terminal through the session — arrives (did not on 1.4.23), also after
  reconnecting and after the pointer left and re-entered; Ctrl+C / Ctrl+V reach the remote too (so copy /
  paste with the keyboard inside a session works again — likely the "clipboard broken" report).
- Windows TBFDesk → Ubuntu (release build): "Share Screen" offers both monitors, both selected, session shows
  2 displays; the next connection starts without the question; mouse and keyboard from Windows work.
- Span mode now covers both monitors (the window could not be placed before).
- Drag: session window from monitor 2 to monitor 1 and back (also maximized); the first toolbar
  click afterwards works; double-click on the header maximizes.
- Clipboard, both directions and with Ctrl+C / Ctrl+V pressed inside the session, Windows ↔
  Ubuntu: works (as it did on 1.4.23 in the lab).

## Known, not in this release
- The FIRST screen-sharing question must be answered within about 30 seconds, or the connecting side
  sees "remote desktop offline" (later connections do not ask).
- HiDPI / fractional scaling under XWayland not tested yet (`TBFDESK_NATIVE_WAYLAND=1` reverts to native Wayland).
- Flutter Linux 1.4.24 follows after its own Wayland check (keyboard, drag).
- Windows installers: the shared changes follow with the next Windows build.
- Fullscreen toolbar: could not be reproduced (drops down in single / all / span / window-per-display
  fullscreen); needs the user's monitor arrangement.

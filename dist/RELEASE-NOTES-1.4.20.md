# TBFDesk 1.4.20 (clients, Sciter + Flutter) and server 1.1.17 — 2026-11-10

First release that ships **both UIs**: Sciter (as before) and Flutter, each with its own
installer and its own automatic-update channel. Same TBFDesk underneath: installing one over the
other switches the machine and keeps ID, device key, settings and policy.

## Files
| | Sciter | Flutter |
|---|---|---|
| Windows | `tbfdesk-1.4.20-x64-install.exe` | `tbfdesk-flutter-1.4.20-x64-install.exe` |
| Ubuntu 24.04, offline (all dependencies inside) | `tbfdesk-1.4.20-ubuntu24.04-install.run` | `tbfdesk-flutter-1.4.20-ubuntu24.04-install.run` |
| Debian/Ubuntu package | `tbfdesk-1.4.20-amd64.deb` | `tbfdesk-flutter-1.4.20-amd64.deb` |
| Arch | `tbfdesk-1.4.20-x86_64.pkg.tar.zst` | `tbfdesk-flutter-1.4.20-x86_64.pkg.tar.zst` |
| Generic Linux | `tbfdesk-client-1.4.20-linux-x86_64.tar.gz` | `tbfdesk-flutter-client-1.4.20-linux-x86_64.tar.gz` |

**Arch packages replaced 2026-11-11 with 1.4.20-2** (same program; packaging only). The first
upload (1.4.20-1) declared too few dependencies and did not start on a clean Arch/CachyOS
(`libpulse-simple.so.0: cannot open shared object file`). It also never enabled the service,
and the Sciter package lacked the `tbfdesk` command. `pacman -U` the new file; switching UI asks
"Remove tbfdesk? [y/N]" — answer yes.

Server: `tbfdesk-server-1.1.17-install.run` (install / update with a dialog; **"Update — keep
configuration" is preselected**, full backup first, checks identity/config/TLS/devices after,
rolls back the binaries if the services do not come up) or the tarball. Every file has a
`.sha256`. Not code-signed (SmartScreen / unknown-publisher UAC on Windows).

## Upgrade order
1. Server to 1.1.17 (needed for the Flutter update channels and the UI badge).
2. Clients: the Windows installers upgrade in place; on Ubuntu run the `.run` or
   `apt install ./….deb`. Automatic updates: upload each installer to its own channel in the
   dashboard (`windows-x64` / `windows-x64-flutter`, `linux-deb[-flutter]`, …); a client only
   takes its own UI's channel and the server refuses an installer uploaded to the wrong one.
3. **Ubuntu 26.04:** 1.4.20 installs on 26.04 and survives the upgrade from 24.04 (tested: noble -> resolute full-upgrade + autoremove; if `do-release-upgrade` offers to remove TBFDesk as obsolete, say no or reinstall afterwards -- the configuration is kept).
   Older `.deb`s depend on `libvpx9`, which 26.04 no longer has (they keep running on the stale
   24.04 copy apt leaves behind, but cannot be installed fresh there): bring clients to 1.4.20.

## Changes since 1.4.19
- **Flutter UI** (Windows, Linux) with the TBFDesk features of the Sciter UI; installer pages,
  "About", the Windows "Apps" list (`DisplayVersion "1.4.20 Flutter|Sciter"`) and the dashboard
  show which UI a machine runs.
- **Managed policy holds offline:** a policy once applied stays in force across restarts and
  while the server is unreachable, until the server replaces it; once managed, the server,
  device key and management switch are locked in the UI (a reinstall + re-provisioning is the
  way out).
- **View styles:** Original / Shrink / Stretch / Adaptive in both UIs.
- **Multi-monitor:** the header / toolbar can be opened on every monitor in full screen (span,
  all, windows modes); the remote cursor shape follows in every full-screen mode; windowed
  sessions respect a taskbar on any edge (Windows and Linux); leaving full screen fits the window
  to its monitor; display windows that open late are closed with the session.
- **Windows:** "Enable RDP session sharing" asks for elevation (it silently did nothing when the
  settings window ran unelevated).
- **Ubuntu packages** carry their own copies of libvpx / libaom / libyuv / libjpeg8, so they
  install on 24.04 and 26.04 and survive the release upgrade; Depends now also lists the
  libraries the client loads at run time (libxdo3, libXi, libXcursor, Wayland, EGL for Flutter,
  PipeWire capture).

# TBFDesk 1.4.21 (clients, Sciter + Flutter) — 2026-11-12 — STAGED, NOT PUBLISHED

Server unchanged: **1.1.17** (release-2026-11-10). Client commit `f831aff40` (branch
`nemo-tdd-flutter`, the same branch the 1.4.20 installers were built from); every binary
shows build id `f831aff40 2026-11-12`.

## Files
| | Sciter | Flutter |
|---|---|---|
| Windows | `tbfdesk-1.4.21-x64-install.exe` | `tbfdesk-flutter-1.4.21-x64-install.exe` |
| Ubuntu 24.04, offline | `tbfdesk-1.4.21-ubuntu24.04-install.run` | `tbfdesk-flutter-1.4.21-ubuntu24.04-install.run` |
| Debian/Ubuntu package | `tbfdesk-1.4.21-amd64.deb` | `tbfdesk-flutter-1.4.21-amd64.deb` |
| Arch | `tbfdesk-1.4.21-x86_64.pkg.tar.zst` | `tbfdesk-flutter-1.4.21-x86_64.pkg.tar.zst` |
| Generic Linux | `tbfdesk-client-1.4.21-linux-x86_64.tar.gz` | `tbfdesk-flutter-client-1.4.21-linux-x86_64.tar.gz` |

Every file has a `.sha256`. Not code-signed. Android: no release APK yet (needs the
release signing key and the TBFDesk icon); the lab tests ran on a debug APK of the same commit.

## Changes since 1.4.20
- **Send any key combination** (both UIs, desktop and phone, remote sessions and the
  console): modifiers incl. AltGr, F-keys, special keys, letters, digits; recent combos
  remembered. Ctrl+Alt+Del stays a direct menu entry.
- **No public hosts:** the client no longer contacts public STUN servers or rustdesk.com
  (IPv6/NAT probes and links removed); only the company server is contacted.
- **Arch packages fixed** (1.4.20 did not start on a clean Arch): complete dependencies,
  service enabled on install, `tbfdesk` command present; OpenSSL is built in, so the
  packages work with Arch's OpenSSL 4 and with OpenSSL 3 systems.
- **Sign-in:** a sign-in the administrator revokes (user disabled, allowed computers or
  admin flag changed) now signs the user out in both UIs instead of showing
  "Invalid token" over a stale address book; German texts for the server's sign-in and
  connection refusals ("Benutzername oder Passwort ist falsch", "Ihr Konto ist nicht für
  TBFDesk freigegeben", "Sie dürfen sich nicht mit diesem Computer verbinden", ...).
- **Phone (Android, Flutter):** console sessions into the phone (shell as the app user,
  no root; like the app itself it can read the app's own files, including its config with
  the device key -- the operator accepted that on 2026-11-11); a tap from a phone controlling another device
  arrived as a right-click; console keyboard repeated words; address book follows server
  changes; Android 17 local-network permission asks with an explanation; screen sharing on
  Android 17.

## Upgrade
In place over 1.4.20 (Windows installers, `.run`, `apt install ./….deb`, `pacman -U`).
Switching UI keeps ID, keys, device key, settings and policy (tested on Windows both ways).
Automatic updates: upload each installer to its own channel as for 1.4.20.

## Tested before staging (2026-11-12)
- Windows 11: upgrade 1.4.20 Flutter -> 1.4.21 Flutter -> 1.4.21 Sciter -> 1.4.21 Flutter,
  ID / key pair / device key (hash) / server settings unchanged each time.
- Phone <-> phone, phone <-> Linux, phone <-> Windows: remote control, input, console,
  file transfer (FLUTTER-PORT.md §9b matrix 2026-11-12).
- Linux packages (all PASS 2026-11-12): Ubuntu offline install on 24.04 without network,
  Sciter↔Flutter switch keeps config, launch under Xvfb, release-upgrade 24.04→26.04, `.deb`
  straight on 26.04 (both UIs); clean-Arch container install + launch (both UIs, OpenSSL built
  in). Logs: `vm/logs/ubuntu-offline-test-1421.log`, `vm/logs/arch-pkg-test-1421.log`.

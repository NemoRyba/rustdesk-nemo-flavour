# TBFDesk 1.4.19 (Windows client) — 2026-10-29

Server unchanged: **1.1.16** (release-2026-10-29b) is the matching server. Linux clients stay on
**1.4.18** (release-2026-10-29b); the Linux uninstaller fix below is in the `tbfdesk-uninstall.sh`
attached here.

## Install / upgrade
- **Windows:** `tbfdesk-1.4.19-x64-install.exe` — double-click, `--silent-install`, or the
  one-call provisioning below. Upgrades in place over 1.4.x and keeps ID, device key and settings.
- **Build:** the Sciter UI build (`--features inline,hwcodec,vram`: UI embedded, H.264/H.265,
  no Flutter), from client `8c1cd06b3`. The installer carries `TBFDesk.exe`, `service.exe`,
  `sciter.dll` (sha256 `4d97528e…80dd56`, the vendored copy in `downloads/sciter-x64/`) and
  `dylib_virtual_display.dll`.
- **Not code-signed:** expect SmartScreen and an "unknown publisher" UAC prompt. Check the
  download against `tbfdesk-1.4.19-x64-install.exe.sha256`
  (`25513782cbc303b8424751f93133e7e144d987b5ccddd077ff96c15cf90b34e8`).

## New: install AND provision a Windows machine in one silent call — no GUI
The setup string the dashboard generates (Device keys → generate → **Download file**, a
`.tbfsetup`: the device key plus the server settings) now goes straight into the installer:

```powershell
$p = Start-Process .\tbfdesk-1.4.19-x64-install.exe -PassThru `
       -ArgumentList '--silent-install', '--import-setup', 'C:\deploy\pc1.tbfsetup'
$null = $p.Handle; $p.WaitForExit(); $p.ExitCode   # 0 done · 1 failed · 2 bad setup value
Remove-Item C:\deploy\pc1.tbfsetup                   # it holds the device key
```

The machine installs, registers with its device key and is managed — nobody opens the client.
A client that is already installed is re-provisioned from a pipe:

```powershell
Get-Content C:\deploy\pc1.tbfsetup | & 'C:\Program Files\TBFDesk\TBFDesk.exe' --import-setup - | Out-String
```

- **Checked first:** every value is validated before anything is installed; a typo or a
  truncated paste exits **2** and leaves the machine untouched.
- **Configures the service** (the process that takes incoming sessions), not the console
  user's possibly roaming profile — writes, reads back, prints what it set. The device key is
  only ever shown as `device key: imported`.
- **Repeatable** (`--import-setup srv.tbfsetup --import-setup pc1.key`), `-` reads stdin.
- **Pass a file or `-`.** The setup string itself on the command line still works but now
  warns: it carries the device key, and every process can read another's command line.
- The installer passes its output and **exit code** through (0 / 1 / 2), so GPO, RMM and
  scripts can act on it.
- A machine whose id you do not know yet: generate the key **unbound** — it appears as
  "key claim pending" in the Peers panel and you Approve it (`DEVICE-KEY-CLAIM.md`).

Full details: `DEPLOY.md` §4.

## Fixed: an uninstall + reinstall brought the old identity back
The uninstallers removed the `TBFDesk` config but not the pre-rename `RustDesk` one
(Windows: user profile, LocalService, systemprofile; Linux: `~/.config/rustdesk`), and the
next install imported it again — old ID, keypair, device key and servers. Both uninstallers
now remove it, including the `.toml.bak` copies. The Linux uninstaller also no longer hangs a
scripted run (`COMPONENTS=…`) on its closing dialog, and prints each result once.

## Tested
`tests/gui/windows_provision.sh` (new suite stage `gui-windows-provision`) on the Win11 VM with
this exact installer, from a wiped machine: clean uninstall (no TBFDesk or RustDesk identity
left) → a bad setup string exits 2 and installs nothing → `--silent-install --import-setup
<file>` exits 0, the service holds this run's device key, the machine polls with it and the
Peers panel shows its policy *in sync* (all confirmed after the run started) → no key in the
output → `Get-Content … | TBFDesk.exe --import-setup -` re-provisions → no key in any log. Also
checked: `start "" /wait` from cmd returns 2 in `%ERRORLEVEL%`; `--help`; the argv warning;
client unit tests (134 passed); the Linux uninstaller in a scratch home (both config dirs, every
component, non-interactive, exit code). Before publishing, `gui-windows` on the same installer,
clicking through the real window: installs over the previous version, the ID registers (not stuck
on "Wird generiert"), the "…" menu and Settings open, the log carries the UI scripts' output with
no script error, the Peers panel shows the policy in sync, and a debug run streams its log into the
launching console.

## Known issue (not new in 1.4.19)
**The device key ends up in the user's profile once the user opens the TBFDesk window.**
The window copies the service's configuration into `%APPDATA%\TBFDesk\config`, device key and
the machine's identity key included. On a roaming profile that copy goes to the profile server.
All earlier versions do the same thing; the unattended install does not cause it. Tracked as
OPEN-TODOS #48, with a proposed fix. Until then, keep the folder out of roaming: GPO *User
Configuration → Administrative Templates → System → User Profiles → Exclude directories in
roaming profile* → add `AppData\Roaming\TBFDesk` (relative to the profile root). The window
re-copies from the local service on every start, so nothing is lost. Remove copies already on
the profile share.

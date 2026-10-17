# TBFDesk — Session Handoff (2026-10-17)

Read this, then [`OPEN-TODOS.md`](OPEN-TODOS.md), which is the **source of truth for open
work**. This file is orientation and recipes only; when the two disagree, OPEN-TODOS wins.

## What this is

A hardened, centrally-managed fork of RustDesk for TBF. Superproject
`/projects/rustdesk/rustdesk-nemo-flavour`, branch **`nemo-tdd`** everywhere (`master` is
a stale May snapshot). Three repos, all on GitHub under `NemoRyba`:

| | path | remote branch |
|---|---|---|
| client | `rustdesk-client-nemo` | `nemo-tdd` |
| server | `rustdesk-server-nemo` | `nemo-tdd` |
| hbb_common | `rustdesk-client-nemo/libs/hbb_common` | `nemo` |

The submodules sit in **detached HEAD**, so push with
`git push origin HEAD:<branch>` — a bare `git push` does nothing and says so quietly.
hbb_common has its own fork remote now (the old "push-blocked" note is obsolete).

## State, 2026-10-17

- **The 2026-10-16 field report is closed.** All six CRITICAL items fixed, plus five more
  defects the walkthrough turned up (see the CRITICAL section of OPEN-TODOS for what each
  one was). Every one was verified through the GUI — real clicks, real pastes, real
  sessions — on Linux and on Windows 11.
- **The rename is done** except packaging. `APP_NAME` is `TBFDesk`, so the install
  directory, the exe, the service, the registry key, `%APPDATA%`, the logs and the URI
  scheme all say TBFDesk, and an existing RustDesk-named install is **migrated** rather
  than orphaned. See [`RENAMING-PLAN.md`](RENAMING-PLAN.md) — Layers 0, 1, 2, 4, 5 done;
  Layer 3 (Linux packaging / bundle ids) open and deliberately pinned so nothing breaks.
- **Live server** runs hbbs `94c12b7` and a rebuilt hbbr, deployed 2026-10-17. Details and
  rollback copies in [`TOPOLOGY-DEPLOYMENT.md`](TOPOLOGY-DEPLOYMENT.md).
  **Deploy hbbr whenever you deploy hbbs** — a stale hbbr is why the Relayed-bytes panel
  had no data for eleven days, and it is the half nobody notices.
- Windows installer `dist/tbfdesk-<version>-x64-install.exe` is produced by
  `scripts/package-windows-client.ps1`.

## Topology

Server VM **`192.168.1.14`** (`dev@`), XCP-ng host `192.168.1.13`, public
**`85.126.226.2`**; office LAN `192.168.0.0/24` behind router B. Routing, the hbbs
`-r`/`--local-ip` rules and the LAN-vs-public client split are in
[`TOPOLOGY-DEPLOYMENT.md`](TOPOLOGY-DEPLOYMENT.md); VM-side changes are scripted in
[`scripts/vm-apply-server-address.sh`](scripts/vm-apply-server-address.sh).

## Secrets — where they are, and what must never be committed

Nothing in this repo should contain them. The admin API token, the live sudo password and
the SSH key (`~/.ssh/dev_remote_access_20260928`, mode 0600) live on the dev box only. The
server's `db_v2.sqlite3` **must never be committed** and must never be checked out over on
the live VM — hbbs holds it open.

## Verifying your own work

**Do not ask the user whether the UI looks right. Look.**

- **Linux lab** — `vm/scripts/lab2-*.sh` drives the whole product through the GUI: hbbs +
  hbbr on the host, clients on their own Xvfb displays and HOMEs, containerised peers (the
  id derives from the MAC, so two clients on one host share an id), the dashboard in a real
  browser over CDP, and a real X clipboard for `Ctrl+V`. Written up in
  [`LAB-VERIFICATION-2026-10-16.md`](LAB-VERIFICATION-2026-10-16.md).
  Two traps that fake convincing bugs are documented there: **Brave must run
  `--headless=new`** (on a bare Xvfb nothing composites, so `ResizeObserver` never fires
  and the dashboard's layout freezes), and **a session runs in a child process** that logs
  to `logs/<app>/connect/`, not the main log.
  Sciter reads `src/ui/*.tis` and `*.css` **from disk** on Linux, so a UI change is a
  restart, not a rebuild.
- **Windows VM** — `vm/scripts/vmctl.sh` is the entry point; start with `vmctl.sh status`.
  Use SSH/PowerShell/SCP for builds, logs and config; reserve screenshots and synthetic
  clicks for things that are genuinely graphical. Launch GUI programs with `vmctl.sh gui`
  or they start in a non-interactive session and are invisible.

## Build recipes

- **Client, Linux (Arch/CachyOS):** `scripts/build-arch-client.sh [--release]`. It pins
  `CC=clang` and points libsodium/OpenSSL at the system copies, because GCC 16 ICEs on the
  vendored sources. Needs a vcpkg tree with static ffmpeg for `hwcodec`; without that
  feature the client silently ships without H.264/H.265.
- **Client, Windows:** on the test VM, `C:\src\winbuild.cmd` run **as a scheduled task**
  (`schtasks /Run /TN tbfbuild`) — a build started over SSH dies with the session; log at
  `C:\src\build.log`. Python is absent there, so generate `src/ui/inline.rs`
  (`python3 res/inline-sciter.py`) and the packer's payload on Linux and copy them in.
  `inline.rs` is gitignored and is what the `inline` feature embeds, so **a .tis/.css
  change that is not regenerated will not appear in a Windows build.**
- **Installer:** `scripts/package-windows-client.ps1` on the VM → `dist\*-install.exe`
  plus its sha256. The name must end in `install.exe` or the packer runs portable instead
  of installing.
- **Server deploy:** see [`TOPOLOGY-DEPLOYMENT.md`](TOPOLOGY-DEPLOYMENT.md).

## Standing instructions from the user

- Commit and push when the work is done — this is no longer gated.
- **Security first**; encryption is never weakened for speed.
- Keep the **default NAT hole-punching** behaviour when a connection carries no port info.
- WireGuard and Tailscale are out of scope.
- Verify as a **user**: click the buttons, paste into the fields, open the dialogs. A
  thing is not fixed because the code looks right.

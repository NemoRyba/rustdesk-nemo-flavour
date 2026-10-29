# TBFDesk — Session Handoff (2026-10-29)

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

## State, 2026-10-29

- **Releases:** latest published `release-2026-10-29b` — client **1.4.18** (Windows installer,
  `.deb`, Arch package, generic tarball) + server **1.1.16** (tarball with the upgrade-safe
  `install.sh`). Client **1.4.19** (Windows: install + provision in one silent call, #47; the
  uninstallers now also wipe the pre-rename `RustDesk` config) is built and VM-tested, **not
  published**; its installer is on the VM at `C:\src\dist\tbfdesk-1.4.19-x64-install.exe`, notes in
  `dist/RELEASE-NOTES-1.4.19.md`. Publish with `gh release create` on this superproject.
- **Open and important:** #48 — an installed Windows client copies the device key and the
  machine's keypair into the user's (roaming) profile; design proposed in OPEN-TODOS, not
  started. #46 (b)/(c), #42 (hwcodec in the `.deb`).
- **Automated tests:** `tests/run-all.sh` (`--quick`, default, `--all`), including real GUI clicks
  on Linux (Xvfb) and on the Win11 VM, the server installer in a clean container, the #43
  applied-policy flow end to end and the #47 unattended provisioning. `tests/README.md` lists
  the stages and the traps that made GUI checks lie. `--all` needs the VM running
  (`vmctl.sh start win11`) and the lab hbbs on the host.
- **Live server:** since 2026-10-26 the operator installs it from the release tarballs; this
  workspace does not touch it. At the #46 field report it ran 1.1.15 with the 21121
  workaround in `/etc/tbfdesk/hbbs.env`; whether 1.1.16 is deployed, ask — or read *Build* in
  the dashboard footer.

### Earlier, 2026-10-17

- **The 2026-10-16 field report is closed.** All six CRITICAL items fixed, plus five more
  defects the walkthrough turned up (see the CRITICAL section of OPEN-TODOS for what each
  one was). Every one was verified through the GUI — real clicks, real pastes, real
  sessions — on Linux and on Windows 11.
- **The rename is done** except packaging. `APP_NAME` is `TBFDesk`, so the install
  directory, the exe, the service, the registry key, `%APPDATA%`, the logs and the URI
  scheme all say TBFDesk, and an existing RustDesk-named install is **migrated** rather
  than orphaned. See [`RENAMING-PLAN.md`](RENAMING-PLAN.md) — Layers 0, 1, 2, 4, 5 done;
  Layer 3 (Linux packaging / bundle ids) open and deliberately pinned so nothing breaks.
- **Live server** ran hbbs `94c12b7` and a rebuilt hbbr, deployed 2026-10-17 (superseded by
  the operator's tarball installs, above). Details and rollback copies in
  [`TOPOLOGY-DEPLOYMENT.md`](TOPOLOGY-DEPLOYMENT.md).
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

The test suite reads the **lab** admin token from the running lab hbbs' command line at run
time (`tests/lib/common.sh` `lab_token`) and never prints or stores it. Device keys issued by
the tests go to the VM in files, never on a `vmctl.sh ps` command line or in grep output, and
are deleted when the stage ends.

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
- **Client + installer, Windows (how 1.4.17–1.4.19 were built):** on the Win11 test VM.
  1. Sync the VM's checkout `C:\src\rustdesk-client-nemo` with a git bundle — its remote is an
     SSH alias the VM cannot use: `git bundle create x.bundle <vm-head>..nemo-tdd` in the
     client repo, `vmctl.sh put x.bundle C:/src/x.bundle`, then on the VM
     `git fetch -q C:\src\x.bundle nemo-tdd` and `git merge -q --ff-only FETCH_HEAD`.
  2. Copy [`scripts/vm-build-windows-client.cmd`](scripts/vm-build-windows-client.cmd) to
     `C:\src\build<ver>.cmd`, set `VER` in it, and run it **synchronously over one held-open
     SSH session**: `vmctl.sh ssh "cmd /c C:\src\build1419.cmd"` (~4 min incremental). It
     regenerates `src/ui/inline.rs` (Python 3.12 is on the VM now), builds
     `--features inline,hwcodec,vram`, packs `C:\src\dist\tbfdesk-<ver>-x64-install.exe`;
     log `C:\src\build-<ver>.log`. Take the sha256 with `Get-FileHash`.
  `inline.rs` is gitignored and is what the `inline` feature embeds, so **a .tis/.css change
  that is not regenerated will not appear in a Windows build** — the script always
  regenerates it. The installer's name must end in `install.exe` or the packer runs portable
  instead of installing. Then test that exact file: `tests/run-all.sh --only gui-windows
  --installer 'C:\src\dist\tbfdesk-<ver>-x64-install.exe'` (and `gui-windows-provision`).
  `scripts/package-windows-client.ps1` is the documented wrapper for a build host of your
  own (`DEPLOY.md` §2); it has not been run end to end.
- **Linux packages:** `dist/pkg-linux.sh <version> <out-dir>` with `PKG_BIN` = an Ubuntu 24.04
  build from the `nemo-gui` container (for the `.deb`) and `ARCH_BIN` = a host inline build
  with hwcodec (Arch package + generic tarball). It refuses a non-inline binary.
- **Server tarball:** `dist/pkg-server.sh <version> <out-dir>` (packs `hbbs`, `hbbr`, the
  systemd units, `rustdesk-server-nemo/dist/install.sh` and the uninstaller).
- **Server deploy:** see [`TOPOLOGY-DEPLOYMENT.md`](TOPOLOGY-DEPLOYMENT.md).

## Standing instructions from the user

- Commit and push when the work is done — this is no longer gated.
- **Security first**; encryption is never weakened for speed.
- Keep the **default NAT hole-punching** behaviour when a connection carries no port info.
- WireGuard and Tailscale are out of scope.
- Verify as a **user**: click the buttons, paste into the fields, open the dialogs. A
  thing is not fixed because the code looks right.

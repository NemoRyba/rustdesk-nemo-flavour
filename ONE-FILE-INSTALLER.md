# One-file installer (dashboard)

**Added 2026-11-12.** An *addition* to the separate installer + `.tbfsetup` + `install.cmd`/
`install.sh` workflow — that is unchanged and still offered. The one-file installer bundles an
uploaded installer **and** a per-device setup string (server settings + the generated device
key) into a single self-provisioning file, so a technician runs just one file.

## Where in the GUI

`/nemo/admin` → **Settings → Device keys → Generate device key**. Each generated profile
(LAN / WAN) now shows, under the existing buttons, an **"Or get it as one file"** block: a
platform picker (only the channels that have an installer uploaded) + **Download one-file
installer**. Needs an installer uploaded under **Settings → Software update → Upload the
installer** for the chosen platform.

## How it works

The device **private** key is never persisted server-side (only the public half is pinned —
`nemo_integration.rs::add_device_key`), so the server cannot rebuild the bundle later. The
browser therefore POSTs the with-key setup string it just received to
`POST /nemo/api/one-file-installer {setup_string, filename, platform}` (admin-token gated,
`Cache-Control: no-store`, body never logged, nothing persisted). The handler resolves the
uploaded installer for `platform` from the published manifest — **note: the Sciter Windows
installer (`windows-x64`) is the manifest's top-level `url`, every other channel is in
`platforms`** — and builds:

- **Windows** (`nemo_onefile::build_windows`): `stub ‖ installer ‖ setup ‖ setup_name ‖
  trailer{magic,u64 inst_len,u64 setup_len,u32 name_len}`. The committed MinGW SFX stub
  (`assets/sfx/tbfdesk-sfx-stub.{c,exe}`, `requireAdministrator` manifest) reads its own
  overlay, carves the two blobs into a fresh `%TEMP%` dir, runs
  `installer --silent-install --import-setup <file>`, returns its exit code. One UAC prompt on
  double-click elevates the whole chain. The setup is passed as a **file**, never on argv
  (H26 — it carries the device key). The stub pauses ("Press Enter to close.") **only on a
  genuine double-click**: a console window we solely own (`GetConsoleProcessList()==1`) in an
  interactive session (`ProcessIdToSessionId != 0`). `GetConsoleWindow()!=NULL` alone was wrong
  — a SYSTEM scheduled task runs in session 0 with a console but no one to press Enter, so it
  hung forever (measured 2026-11-16). With the three-part gate: a SYSTEM/service/RMM run never
  pauses (session 0, or no console under `CREATE_NO_WINDOW`); an **already-elevated** shell
  (admin cmd/PowerShell, or SSH) shares its console (count ≥ 2) and never pauses; a genuine
  double-click (own console, count 1, interactive session) pauses so its window stays up. NB a
  **non-elevated** shell run is UAC-elevated into its OWN fresh console, so that elevated child
  *does* pause — the person sees the result window, which is the wanted behaviour. All three
  session-1/0 branches were re-verified on the VM. Rebuild the stub with `assets/sfx/build-stub.sh`
  (needs `x86_64-w64-mingw32-gcc`) and commit the new `.exe`; the server `include_bytes!`s the
  committed binary and never cross-compiles at build time.
- **Linux** (`nemo_onefile::build_linux`): a POSIX-sh self-extracting `.run` — header carves the
  appended `installer ‖ setup` by byte offset after a marker line, installs the package
  (apt/dnf/pacman per channel), then provisions with the **installed binary, which is
  `rustdesk` on Linux** (the fork keeps the upstream binary/.desktop names; the `.run`
  resolves `command -v tbfdesk || command -v rustdesk`). Run as root (`sudo sh <file>`).
  NB this was a real bug found 2026-11-16 — the `.run` originally called `tbfdesk`, which does
  not exist after install, so provisioning failed with `tbfdesk: not found` while the package
  installed fine. Fixed in `build_linux`.

## Code

- `rustdesk-server-nemo/src/nemo_onefile.rs` — pure builders + trailer parser + unit tests.
- `rustdesk-server-nemo/src/nemo_management.rs` — route `/nemo/api/one-file-installer`, handler
  `post_one_file_installer`, helpers `one_file_setup_name` / `one_file_out_name`.
- `rustdesk-server-nemo/src/nemo_admin.html` — the picker + `Download one-file installer` button
  (`downloadOneFile`, `fillOneFileSelect`, `ONEFILE_NAMES`); the old buttons are untouched.
- `rustdesk-server-nemo/assets/sfx/` — stub source, manifest, `.rc`, `build-stub.sh`, prebuilt exe.

## Verified (lab, 2026-11-12 and 2026-11-16)

- **Unit tests** (trailer round-trip, garbage/truncation rejection, Linux header layout,
  sanitising) pass. The no-installer→400 and the download-name derivation were verified **live**.
- **Byte-exact bundles** for `windows-x64`, `windows-x64-flutter`, `linux-deb`: the Windows
  overlay and the Linux `.run` carve back **byte-for-byte** to the exact installer + setup string.
- **Both flavours actually installed on the Win11 VM (Defender ON)** with a discriminating
  `sha256(nemo-device-key)` match to each run's freshly-generated private key:
  - **Flutter `.exe`** installed as a SYSTEM task → Flutter bundle present, key `e4396ad4…` exact.
  - **Sciter `.exe`** installed from an elevated SSH session → Sciter, key `3c8c83a2…` exact.
- **Terminal-context matrix (2026-11-16):** already-elevated contexts (SYSTEM task, admin/SSH
  terminal) install with **no UAC**. A non-elevated user **cmd** and **PowerShell** each raise a
  **UAC prompt** (unknown publisher — the stub is unsigned); approve → installs + provisions
  (seen on screen, "Installation erfolgreich"); decline → PowerShell reports "operation was
  canceled by the user". So the only gate is elevation, not which shell.
- **Pause-gate bug found + fixed (2026-11-16):** a SYSTEM `/tr <exe>` task (no stdin redirect)
  installed then **hung forever** at `getchar()` under the old `GetConsoleWindow()` gate. New
  three-part gate re-verified across three cells: SYSTEM direct → clean exit 0; elevated cmd →
  no pause; interactive own-console (double-click equivalent) → still pauses (window stays).
- **Linux `.run` run end-to-end in a clean `ubuntu:24.04` container:** found the
  `tbfdesk` → `rustdesk` binary-name bug, fixed it, then the full `.run` printed `Done.`,
  installed `/usr/bin/rustdesk` + deps, and imported the key (hash `2e353dda…` exact match).
- **Server-side device-key auth confirmed:** built a Flutter one-file pointed at the host
  (`10.0.2.2`), installed it; the VM (peer `12513041`) presented the one-file's **exact key**
  `jbmZeZsyq1ByhzVX` to the server (pending claim, 10 attempts, rendezvous handshake), approved
  → the peer now authenticates `auth_mode=device-key`. The VM ends on Flutter + polling the host.

**Not exercised:** a literal Explorer **double-click** (shown instead via the equivalent
own-console interactive task, and via the cmd/PowerShell UAC path). The **Flutter** `.exe` through
the UAC path specifically (Flutter proven via SYSTEM; the UAC path was proven with Sciter). The
browser **Download one-file installer** button (code-verified — it POSTs the same proven endpoint
and saves the `Content-Disposition` name — but not clicked in a browser this session). The Linux
`.run` was run only for `deb` on Ubuntu 24.04 and needed a prior `apt-get update` (a real desktop
has package lists); rpm/arch not run. What the logged-in user sees after a session-0 install
(tray/shortcuts) not inventoried.

## Trade-off

The one-file carries the device key inside a downloadable binary — same posture as the legacy
`host=,key=` custom client. The dashboard tells the operator to **move it like a password**.

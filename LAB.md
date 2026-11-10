# TBFDesk lab — map, access, bring-up

The one place that says what the lab is, how to get into each part of it, and how to tell
whether it is still consistent. Dated reports (`LAB-VERIFICATION-*.md`, `HANDOFF-*.md`)
record what was true on one day; **this file is kept current**. If you change the lab,
change this file in the same sitting.

Everything lives on the workstation under `/projects/rustdesk/vm/` (NOT in git — this file
is its only versioned description). Last verified: **2026-11-06**.

## Step 0 — is the lab stale?

```bash
/projects/rustdesk/vm/scripts/lab-status.sh
```

Read-only, ~5 s, prints no secrets. It reports: lab server up + build + enforcement flags,
which peer ids the server knows, which client binary the lab scripts run (and whether it
is an **inline** build and older than the checkout), container states and IPs, every
client HOME with a device key **and whether the server still knows that id**, VM states.
Every `WARN` / `STALE` line names the fix. Run it before any test; do not rediscover.

## Map

| Part | Where / how | Access |
|---|---|---|
| **lab2 server** (hbbs + hbbr on the host) | `vm/scripts/lab2-up.sh` (kills + restarts both). State `vm/lab2/` (server key `id_ed25519`, `db_v2.sqlite3`, `nemo_integration.json`). Logs `vm/logs/lab2-hbb{s,r}.log` | rendezvous `127.0.0.1:21116`, relay `:21117`; containers reach it as **`169.254.1.2`**. Admin API/GUI `https://127.0.0.1:31120/nemo/admin`, bearer token in **`vm/lab2/token`** (`-H "Authorization: Bearer $(cat vm/lab2/token)"`, self-signed TLS → `curl -k`) |
| **Container peers** `nemo-peer2..7` | podman, bridge `nemolab` 10.89.0.0/24 (peer2 = .2, peer3 = .3, …). Each mounts the client repo **read-only** at `/client`, `vm/lib` at `/sciter` (libsciter-gtk.so, libyuv.so), and `vm/lab-clients/peerN-home` at `/home/peer` (writable). Own Xvfb `:99` + openbox inside. Drivers: `lab2-peer.sh` (`LAB2_CT=nemo-peer3`), `peerclick.sh`, `peershot.sh` | `podman start nemo-peer2 nemo-peer3`; `podman exec nemo-peer2 bash -c 'DISPLAY=:99 …'`. The host **cannot** route into a container; containers reach each other directly and the host at 169.254.1.2 |
| **Host clients** | `lab2-client.sh fresh|start <name> <:disp>` — own Xvfb + HOME under `vm/lab-clients/<name>` | `lab2-client.sh shot|click|type|key …` |
| **Win11 test VM** (also win10) | `vm/scripts/vmctl.sh` is the only entry point: `status`, `start`, `ssh`, `ps`, `put/get`, `gui`, `shot`, `input` | user `tbf`, SSH key `vm/run/vmkey`; password in `vm/unattend/win11-autounattend.xml`. Ports are discovered by `vmctl.sh status` — never hard-code them. Toolchain + source in the guest at `C:\src` (see `HANDOFF.md`, memory "Windows client build") |
| **Linux controller VM** (Arch, distinct device identity) | `vm/linux-vm/lxvm-lab.sh net-up|start|ssh|console|stop` | SSH host:2222 → guest, key `vm/linux-vm/lxvm_key`; lab-plane IP 10.66.0.30 on bridge `owwan` |
| **OpenWrt edge router** (port-knock tests) | `OPENWRT-FWKNOP-LAB.md`, `ROUTER-KNOCK-RUNBOOK.md`; files `vm/openwrt/` | see those docs |
| **Physical controller** `mareks-lenovo` (Win10 Home, via Tailscale) | `vm/scripts/lenovo.sh push|facts|probe|direct-test|shot|log` | `ssh mareks-lenovo` (key `~/.ssh/mareks-lenovo_ed25519`); see `HANDOFF-LENOVO-PC2-DIRECT.md` |
| **LDAP** (only when a test needs login) | containers `nemo-ldap` / `tbf-ldap` (both normally stopped). `nemo_integration.json` currently has `ldap.enabled = false` | ldaps only — the server refuses plain `ldap://` |
| **Pentest kit** | container `kali-attack`, `pentest/` | `pentest/FINDINGS.md` |
| **Automated suite** | `tests/run-all.sh` (`--quick`, default, `--all`) | `tests/README.md` |

Credentials that are only lab throwaways live next to what they unlock (token file, unattend
XML, key files above). Never paste a device key, token or password into a command line,
grep output or a doc — ship it in a file.

## Two ways to get a remote session

### A. Unmanaged, by ID over a direct endpoint — fastest, needs no enrollment

Works even when the managed lab is stale. Two fresh clients in the containers:

- **Target** (peer3): fresh HOME, `~/.config/tbfdesk/TBFDesk2.toml` options
  `direct-server = 'Y'`, `verification-method = 'use-permanent-password'`, and
  `TBFDesk.toml` `password = '<plaintext>'` (migrated to a salted hash on first load).
  Listens on `10.89.0.3:21118`.
- **Controller** (peer2): fresh HOME, options
  `nemo-direct-endpoints = '<targetId>,10.89.0.3:21118'` and
  `nemo-peer-keys = '<targetId>,<target Ed25519 pubkey, base64>'`, then
  `rustdesk --connect <targetId> --password-file <file mode 600>`.
  The target id is in its log (`Generated id N`), the pubkey is the 32-byte second half of
  its `key_pair` in `TBFDesk.toml`.

`vm/scripts/cursor-shape-test.sh` does exactly this end to end (and is the worked example
for driving + measuring a session). Result: a **"Direkt"** session.

**Do not** use `--connect <ip>`: this fork's target always opens the secure handshake on
its direct port, a bare-IP controller never answers, both sides wait out the 18 s
`CONNECT_TIMEOUT`, and the controller sits on "Verbindung wird hergestellt" forever.

### B. Managed (device keys, policy, knock) — the product path

The server enforces `require_device_key` and `require_sealed_login`. Enrollment chain
(admin API): mint a device key (`POST /nemo/api/device-keys`) → write it into the client's
`nemo-device-key` → bind it to the peer id → allow the peer → give the controller a policy
with `nemo-outbound-enabled: Y` and the target in `nemo-outbound-targets` → (login if the
policy requires it). Full recipe: memory note "TBFDesk Linux VM controller" /
`DEVICE-KEY-CLAIM.md`. **The ids are MAC-derived**, so two clients on one host collide —
use the containers or the VMs.

### C. Cursor tests (remote cursor shape) — `vm/scripts/cursor-lab/`

Ground truth on both ends, never screenshots: XFixes on Linux (`curprobe`), and on
Windows `ct-probe2.ps1` in the interactive session (GetCursorInfo + bitmap hash, writes
`C:\src\curnow.txt`). Windows VM as an unmanaged direct target: `ct-setup.ps1` (backs up
the service config, `ct-restore.ps1` undoes it) + `vmctl.sh monitor 'hostfwd_add
tcp::21128-:21118'`; containers reach it at `169.254.1.2:21128`. Linux target with a
known cursor per region (and a cursor change while a button is held): `cursorgrid.py`.
Two real monitors for a controller: Xvnc + `xvnc-two-heads.py` (see `rdp-multimon.sh`).

**Multi-monitor is the normal case** (the users have several monitors on both ends): any
session/UI change is tested in all four display modes, not just single.

- `multidisplay-cursor-test.sh [worktree] [modes]` — host only: target on Xvnc `:61` with
  two outputs + `cursorgrid.py`, controller on Xvnc `:47` with two outputs; per mode it
  presets the per-peer `nemo-display-mode`, connects, and samples a grid on both monitors
  (`UI=<dir>` runs another `src/ui` with the same binary; `TAG=` names the result dir).
- `win-multidisplay-cursor-test.sh [exe] [modes]` — the Windows controller: VM switched
  with `ct-setup.ps1` + `ct-endpoint.ps1`, two monitors via `rdp-multimon.sh start :45`,
  `ct-probe2.ps1` running in the session; same host target. Undo: `ct-restore.ps1`,
  `rdp-multimon.sh stop :45`, **then put the session back on the console** over SSH
  (`query session`, `tscon <id> /dest:console`) — otherwise it stays a disconnected RDP
  session: `vmctl.sh shot` shows a lock screen and `vmctl.sh gui` launches go nowhere.

Findings 2026-11-06: every single-display combination (Linux/Windows either side, button
held or not) follows the remote cursor; in "all" / "span" / "windows" the controller
showed only its local arrow (installed Windows 1.4.19: all 4/6, span 29/32, windows 29/32
points wrong) — fixed by client 124921284 on `nemo-tdd-multidisplay-cursor` (0 on Linux
and on a Windows inline build).

## Flutter builds (Linux, Windows VM, Android emulator) — set up 2026-11-06

Toolchain under `/projects/rustdesk/tools/` (not in git): Flutter 3.24.5 (+ CI's
dropdown patch), JDK 17 (Gradle only), Android SDK (platform 37.0 + 34/36, build-tools 37,
NDK r28c, emulator), `flutter_rust_bridge_codegen` 1.80.1 + `cargo-expand`, a vcpkg git clone
at CI commit 120deac (Android deps), and a user-local rustup (Android targets, `cargo-ndk`
3.1.2). `source tools/env.sh` for everything; add `source tools/env-android.sh` for Android
builds only (its rustup must not shadow the system rust used for Sciter).

| Build | Recipe (client repo, branch `nemo-tdd-flutter`) |
|---|---|
| bridge | `CPATH=/usr/lib/clang/23/include flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h` — **without CPATH** libclang misses `stdbool.h`, logs SEVERE and still says "Success" with wrong FFI types |
| Linux | build env as Sciter (CC=clang …) + `cargo build --features flutter,hwcodec,unix-file-copy-paste --lib --release`, then `cd flutter && flutter build linux --release` → `flutter/build/linux/x64/release/bundle/rustdesk` |
| Windows | VM: `C:\src\buildflutter.cmd` (vcvars + `cargo build --features flutter,hwcodec,vram --lib` + `flutter build windows`) → `flutter\build\windows\x64\runner\Release\rustdesk.exe`. Sync sources with a git bundle + `tar` of the 4 generated bridge files (gitignored). Flutter needs the VS components *C++ CMake tools* and *Windows 11 SDK* **registered with the VS installer** (`setup.exe modify … --add …` via `start /wait`; `--wait` is not an option of setup.exe) |
| Android deps | `VCPKG_ROOT=tools/vcpkg CC=clang CXX=clang++ flutter/build_android_deps.sh x86_64` (the yay vcpkg is a tarball → manifest baseline fails; system gcc ICEs on aom) |
| Android | `cargo ndk --platform 21 --target x86_64-linux-android build --release --features flutter,hwcodec`; copy `liblibrustdesk.so` → `flutter/android/app/src/main/jniLibs/x86_64/librustdesk.so` **and** the NDK's `libc++_shared.so` next to it; `flutter build apk --debug --target-platform android-x64` |
| Emulator | AVD `tbf-pixel7a` (Pixel 7a profile, Android 17 / API 37.0, google_apis x86_64): `emulator -avd tbf-pixel7a -no-window -gpu swiftshader_indirect -no-audio -no-snapshot-save`; app `at.tbf.tbfdesk/com.carriez.flutter_hbb.MainActivity` (`adb shell am start -n …`; `monkey` does not start it) |

Traps: `.github` CI pins are the reference (`flutter-build.yml`, `bridge.yml`). The Flutter
`rustdesk` bundle and the Sciter binary share one IPC socket per user
(`/tmp/TBFDesk-<uid>/ipc`): a second TBFDesk on the host attaches to the first and **copies
its config** ("config synced" in the log) — stop every other TBFDesk before starting a lab
client (`multidisplay-cursor-test.sh` refuses to run otherwise).

Android session on the emulator (2026-11-11): build with `vm/scripts/android-build.sh`
(stops on a failed cargo step; a piped `cargo | tail` once hid one and packed a stale lib).
Emulator to host target = recipe A with `nemo-direct-endpoints = '<id>,10.0.2.2:<port>'`
(10.0.2.2 = host loopback) appended to `app_flutter/TBFDesk2.toml` via
`adb shell run-as at.tbf.tbfdesk` while the app is stopped. Traps:
- **Android 17 local-network permission:** without `ACCESS_LOCAL_NETWORK` granted, every
  connect from the APP to a private address times out, while `adb shell nc` to the same port
  works (the shell is exempt). The app asks at first start since client 5e05bdfce; on a
  reinstall tap Allow, or `adb shell pm grant at.tbf.tbfdesk android.permission.ACCESS_LOCAL_NETWORK`.
- **App log:** `app_flutter/Logs/rs_rCURRENT.log` (since hbb_common 1a1eb73; before that,
  `/sdcard/TBFDesk/Logs`, which needed all-files access, so usually no log at all). Read it with
  `adb shell run-as at.tbf.tbfdesk cat app_flutter/Logs/rs_rCURRENT.log`.
- uiautomator: Flutter labels are `content-desc`, not `text`.

## Builds the lab runs — the inline trap

The lab scripts run `rustdesk-client-nemo/target/release/rustdesk` from **whatever branch is
checked out** in the client repo, built whenever someone last built it.

- **Inline build** (packaging / release builds): the `.tis` UI is compiled into the binary;
  editing `src/ui` changes nothing until you rebuild. It looks for libsciter **only** at
  `/usr/share/rustdesk/libsciter-gtk.so` or `$APPDIR/usr/share/rustdesk/…` and **ignores
  `LD_LIBRARY_PATH`** (it panics "libsciter-gtk.so was not found" in the containers).
  Detect: `grep -qa share/rustdesk/libsciter-gtk.so <binary>`.
- **Non-inline** (`scripts/build-arch-client.sh --release`): UI loaded from
  `<cwd>/src/ui` at run time, libsciter via `LD_LIBRARY_PATH=vm/lib` (`/sciter` in the
  containers). This makes UI A/B tests free: one binary, two `src/ui` trees.
- To test a branch without touching the main checkout: a worktree under `vm/build/`
  (e.g. `vm/build/client-nemo-tdd`, branch `nemo-tdd`), seeded with `cp -a` of the main
  `target/release` → incremental release build ≈ 2.5 min. Init its `libs/hbb_common`
  submodule from the local clone
  (`git -c protocol.file.allow=always -c submodule.libs/hbb_common.url=<main>/libs/hbb_common submodule update --init`).
- Config dir of current builds: `~/.config/tbfdesk/TBFDesk*.toml`, logs
  `~/.local/share/logs/TBFDesk/` (a session's own log is under `…/connect/`).

## Session tests: both UIs, two monitors each side (2026-11-06)

One command: `tests/run-all.sh --only session-linux` (≈45 min; part of `--all`). It runs, for
the Sciter viewer (lab worktree `vm/build/client-nemo-tdd`) and the Flutter bundle
(`rustdesk-client-nemo/flutter/build/linux/x64/release/bundle`):

| Script (`vm/scripts/…`) | Proves |
|---|---|
| `cursor-lab/multidisplay-cursor-test.sh` | single / all / span / windows on 2 local monitors against a 2-display target: the remote cursor (9 shapes, 32 px) on every point; per mode screen / cursor / input delay, fps at a 30 Hz full-screen flip, CPU, RSS (`perf.txt`) |
| `cursor-lab/input-test.sh` (`LAYOUT=us\|de`) | text, special keys, 12 shortcuts (incl. Ctrl+Alt+Del, Super, Alt+Tab), German layout with **AltGr** (@ € [ \\ ~) and umlauts, left/middle/right/double click, 4 wheel directions, drag — checked on the target by `inputlog.py` |
| `cursor-lab/hold-test-linux.sh` | the cursor while a button is held (drag/resize) and after release |
| `cursor-lab/multidisplay-cursor-test.sh` with `FULLSCREEN=1` (and `win-multidisplay-cursor-test.sh`) | the same cursor grid with every session window put in full screen by the APP's own button (`cursor-lab/fs-click.py`; neither UI has a shortcut) — the multi-monitor full-screen case (2026-11-10) |
| `cursor-lab/viewstyle-test.sh`, `win-viewstyle-test.sh` | Original / Adaptive / Shrink / Stretch measured (green grid cell height / 267) in a window smaller and larger than the remote screen |
| `cursor-lab/workarea-test.sh`, `win-workarea-test.sh` | "windows" mode with the controller's taskbar at the top / left / right / bottom (fake panel on Linux, StuckRects3 on Windows): every window maximized inside its own monitor's work area |
| `cursor-lab/win-fsexit-test.sh` | leaving full screen: the window fits its monitor again (not larger, not off-screen) |
| `cursor-lab/dispbar-test.sh`, `win-dispbar-test.sh` | Sciter "windows" mode: the extra display window's own bar — full screen on / off (picture shown), all displays back in one window |
| `cursor-lab/lone-move-test.sh` | a single pointer move over an idle session window arrives at once (R21) |
| `policy-lab/policy-sticky-test.sh` | a managed policy holds while the server is unreachable, until the server changes it |
| `install-lab/update-channel-test.sh` | Windows auto-update per UI: an older Sciter / Flutter install updates itself to the 1.4.x of its own UI with both published |
| `console-lab/console-test.sh` | console session: a real remote shell answers; refused with a message when the target has "Enable terminal" off |

Windows viewer: `cursor-lab/win-multidisplay-cursor-test.sh <exe>` (RDP two monitors,
`rdp-multimon.sh`, probe `ct-probe2.ps1`, VM pointed at the host target by
`ct-endpoint.ps1` — copy the target's `TBFDesk.toml.pub` to `C:\src\ct-target.pub` first).
Windows as console *target*: install the build into the VM service (skill
`rustdesk-vm-control` RECIPES/TODO), `ct-setup.ps1`, `vmctl.sh monitor 'hostfwd_add
tcp::21128-:21118'`, then `console-lab/console-pty.py <bin> 12513041 <pw> run 'ver' 'Microsoft Windows'`.

Windows viewer, more (2026-11-09): `cursor-lab/input-test-win.sh <exe>` (real key / mouse
events through the agent's new `CHORD` / `MOUSE`), `cursor-lab/win-hotplug-test.sh <exe>`
(the RDP client reconnects with 1 then 2 monitors = unplug / replug under the running
viewer), `cursor-lab/win-sync-target.sh` (refreshes the VM's endpoint key — every Windows
script runs it), `winrects.ps1` (window rect + maximized + monitor work areas, in-session).
Linux "windows" placement: `cursor-lab/fakepanel.py` (a taskbar strut),
`windows-lifecycle-test.sh`, `hotplug-test.sh`; `wmstate.py` (EWMH maximize/restore —
`xdotool windowstate` does not reach openbox).

Accepted, known: Sciter on **Linux** reports a horizontal wheel as vertical (the
libsciter-gtk engine does), so its two horizontal-wheel steps fail; Flutter passes them.

## Ubuntu packages: offline install + release upgrade (2026-11-10)

`vm/scripts/install-lab/ubuntu-offline-test.sh <dir with .run/.deb> [version]` -- containers
only, ~15 min: offline `.run` install in `ubuntu:24.04 --network none` (Sciter, then Flutter
over it, a config marker must survive), library check + start under Xvfb
(`ubuntu-launch-check.sh`), simulated 24.04 -> 26.04 upgrade (sources noble -> resolute,
`full-upgrade`, `autoremove --purge`), and the `.deb` on a clean `ubuntu:26.04`. Logs in
`vm/logs/ubuntu-offline-<v>/`. Trap: `ldd` on a Flutter plugin `.so` alone reports
`libflutter_linux_gtk.so => not found` -- the plugins find it through the executable's
RUNPATH; check with `LD_LIBRARY_PATH=/usr/share/rustdesk/lib`.

## Making the lab fresh again

| Symptom (`lab-status.sh`) | Cause | Fix |
|---|---|---|
| hbbs/hbbr not running | host rebooted | `vm/scripts/lab2-up.sh` |
| `STALE: server has no record of this id` | server DB was reset/replaced after the client enrolled | re-run the enrollment chain (B) for that client, or use recipe A |
| peer HOME has no config | someone ran `lab2-peer.sh fresh` (it wipes) | re-provision (`run-peer-container.sh <ct> <devkey-file>`), or recipe A |
| binary older than checkout / INLINE | last build was a packaging build or another branch | build non-inline in a `vm/build/` worktree |
| containers `exited` | normal after a reboot | `podman start nemo-peer2 nemo-peer3` |

State as of 2026-11-05: the server knows only `12513041` (Win11 VM, blocked); peer2's
config is wiped; peer3's enrolled config (id 13301327) is unknown to the server; the
Windows and Linux VMs are stopped. Recipe A works regardless. The `win10` disk was never
installed (197 KB); Win11 is the only Windows VM — the real Win10 box is the lenovo.

## Traps that produce false results (each cost real time)

- **The fake taskbar on :47 sits at the TOP** (`fakepanel.py bottom 40`, left running by the
  windows-mode work-area tests; openbox docks it at the top) and covers the top 40 px of every
  session window. Sciter reveals its auto-hidden header only from the window's top edge, so
  with the panel up the header (and its fullscreen button) cannot be reached. Kill it before
  any test that needs the header (`cursor-lab/fs-click.py`, FULLSCREEN=1).
- **Changing a display's monitors dropped the viewer stub** (it announced raw encoding only;
  Xvnc disconnects a client that cannot take a resize): every hot-plug step after the first
  ran unwatched, and Flutter's monitor switches looked ~20 s slow, all on 2-s timer ticks.
  `xvnc-viewer-stub.py` now announces DesktopSize and reconnects by itself (2026-11-10).
- **The same Xvnc frame pacing also delays a lone pointer move** (~480 ms unwatched, ~12 ms
  watched) — FLUTTER-PORT R21; `cursor-lab/lone-move-test.sh`.
- **An unwatched Xvnc throttles GL clients**: TigerVNC paces Present/vblank through its VNC
  update loop, which only runs while a viewer is connected. Flutter (GL) then gets ~1 frame
  per 1.5 s and lags input as much (looked like "Flutter is 100x slower"); Sciter does not
  notice. `vm/scripts/xvnc-viewer-stub.py <rfb-port>` keeps a display watched — the cursor
  and input scripts start it for :47.
- **Peer files without `[info] platform` are deleted** by the Flutter home page (upstream
  `PeerConfig::batch_peers`) — a hand-written `peers/<id>.toml` with only `[options]` loses
  e.g. `nemo-display-mode` the moment the main window starts. Always write `[info]` too.
- **`scripts/build-arch-client.sh` always builds the MAIN checkout** (it cd's there) and
  overwrites `target/release/liblibrustdesk.so` — which `flutter build linux` then copies
  into the bundle → "rustdesk_core_main not found". Main checkout = Flutter
  (`cargo build --features flutter,… --lib`), Sciter lab builds in `vm/build/*` with cargo.
- **AltGr in xdotool is not a keyboard's AltGr**: on the lab Xvnc, xdotool types AltGr
  characters through keycode 92 (evdev LVL3), a key no PC keyboard has; RustDesk maps the
  real AltGr = right Alt = keycode 108. Press 108 (`input-test.sh LAYOUT=de` does) — with
  92 every AltGr character "arrives without AltGr" in both UIs.
- **`vmctl.sh input FOCUS a b`** takes only the first word: focus by a unique single word.
- **Session processes (`--connect`, `--terminal`) read the user's config file**, which only
  the running main window keeps in sync with the service: with no main window open (after a
  VM reboot) they use stale options (old peer keys → "direct peer signature invalid").
  Start the main window first (`C:\src\rungui.cmd`).

- **`$!` after `setsid …` is not the client's PID**: setsid forks when it is already a
  process-group leader, so killing the saved PID does nothing and old sessions (with their
  display windows) stay open and answer the next test. Launch with plain `nohup`, and kill
  by `HOME` in `/proc/<pid>/environ` (`kill_clients` in `multidisplay-cursor-test.sh`).
- **Xvfb + `xrandr --setmonitor` is unreliable**: it returns 0 and then lists only
  "screen" (one display — the multi-display modes are never offered). Use Xvnc with real
  outputs (`xvnc-two-heads.py`) for targets as well as controllers.
- **`pkill -f` / `pgrep -f` kill or match their own shell** — on the host too, not only
  inside `podman exec`. Match `pgrep -x <name>` and check `/proc/<pid>/cmdline`.
- **`pkill -f` inside `podman exec … bash -c '…'` kills its own shell** whenever the pattern
  text — even `[x]yz` — or the matched path occurs anywhere in that same command string.
  Use `pkill -x <name>` or a pidfile. The script then dies silently mid-run.
- Session window's X name is `rustdesk` (main window `TBFDesk`); the peer id/IP shown in
  its title bar is drawn by Sciter. `xdotool search --pid` finds nothing (no
  `_NET_WM_PID`) — search `--name '^rustdesk$'`.
- Screenshots (`import`) never contain the pointer. To assert a cursor shape, read it with
  XFixes: `vm/lab-clients/peer2-home/cursortest/curprobe [out.ppm]` (source in
  `cursor-shape-test.sh`'s history; `gcc curprobe.c -lX11 -lXfixes`).
- Sciter ignores a click on an element that has not seen the pointer: move, wait 0.5 s, click.
- Brave for the admin GUI must run `--headless=new` (no compositor on Xvfb → frozen layout).
- Lab relay from a host client never works (hbbr treats loopback as its admin console).
- `zsh`: `echo =====` is a command lookup, `local path=…` clobbers `$PATH`, and **`echo`
  interprets backslashes** — `echo 'C:\src\config'` turns `\c` into "stop output" and
  `\r` into a carriage return. Pipe PowerShell to `vmctl.sh ps` with `cat <<'EOF'`.
  `$var` with spaces is not word-split (`set -- ${=p}`).
- **VM at the lock screen, autologon dead:** the `tbf` password had expired (42-day
  default). Fixed 2026-11-05 with `Set-LocalUser tbf -PasswordNeverExpires $true`; to log
  in by hand, send the unattend password through the monitor (`sendkey`), never argv.
- **QEMU `mouse_move` arrived as relative jumps** in the Win11 VM (pointer pinned at
  1279,799 = the "show desktop" corner, everything minimised). For in-guest pointer moves
  use a script in the interactive session calling `mouse_event(MOVE|ABSOLUTE)`
  (`vm/scripts/cursor-lab/ct-probe2.ps1` polls `C:\src\ctmove.txt` = `x y [down|up]`).
- `vmctl.sh gui` deletes its task after 3 s, which can cancel the launch; for anything
  that matters create the `/it` task yourself and keep it ≥ 8 s.
- **A Linux *target* on the host** refuses every session with "Wayland login screen not
  supported" (the host's seat0 has an sddm greeter; `loginctl` is called by absolute
  path). Run it with `FLATPAK_ID=x` and a failing `flatpak-spawn` stub first on `PATH`.
  Two TBFDesk processes on the host share one IPC (`/tmp/TBFDesk-<uid>/ipc`): a host
  controller reads its options from the host target, so give the target the
  controller's `nemo-direct-endpoints` / `nemo-peer-keys` too.
- A config written by the client stores `key_pair` as a **multi-line** array; drop the
  whole array when editing, or the next load fails "Bad TOML" and regenerates id + key.
- More, per area: `tests/README.md` (GUI suite), memory notes listed in `MEMORY.md`.

# TBFDesk test suite

One command runs every automated check — Rust unit tests, cross-repo contract checks, the
UI build pipeline, and **real GUI tests that click through the client** on Linux (Xvfb) and on
the Win11 test VM, reading the screen with OCR and checking the logs.

```bash
tests/run-all.sh                 # unit + contract + static + parity + Linux GUI   (default)
tests/run-all.sh --quick         # unit + contract + static + parity only      (no display, no lab)
tests/run-all.sh --all           # + Windows VM: unattended provisioning, GUI test, #43 end-to-end
tests/run-all.sh --only gui-windows --installer 'C:\src\dist\tbfdesk-1.4.19-x64-install.exe'
TBF_FULL=1 tests/run-all.sh --all  # + the slow checks (#43 "stale" after 2 min offline)
```

Each stage prints `OK`/`FAIL` lines, then a summary with timings. Exit code is non-zero if any
stage failed. Artifacts (logs, screenshots of failed GUI checks) go to `/tmp/tbf-tests/<run-id>/`.
A stage whose prerequisite is missing (no lab server, VM off) reports **SKIP**, not FAIL.

**Lab-only.** The GUI/e2e stages talk to the local lab `hbbs` (`vm/lab2`, admin token read
from its own command line, never printed) and the Win11 test VM. Nothing touches production.

## Stages

| Stage | What it proves | Needs |
|---|---|---|
| `unit-server` | `cargo test` of hbbs/hbbr (125+ tests), incl. #43: policy ref stability, report bounds, report signature (tamper / wrong peer / stale), every state transition, per-role storage, source labels | Rust |
| `unit-client` | `cargo test --lib` of the client (130+ tests), incl. #43 report building and the server signature contract, and the **1.4.16 regression guards** (below). Run by `tests/unit/client.sh`: `test_get_cursor_pos` gets a throwaway Xvfb when the session has no display; `test_desktop_env` is skipped (printed `SKIP … reason`) when seat0 belongs to another user, e.g. the login screen while you work remotely | Rust + `tests/lib/client-env.sh`, Xvfb |
| `contract` | client and server agree on the #43 report: every refusal code the client can send is one the server accepts; same signature domain; same fields | Python |
| `parity` | **Sciter ⇄ Flutter parity from the source, both directions** (`tests/parity/inventory.py --check`): every Sciter menu entry / input / toggle / option key / binding has a Flutter counterpart, and every option key Flutter reads or writes and every Flutter settings row has a Sciter one; plus behaviour notes for keys both UIs use (one greys the row when the administrator fixed the option and the other does not; different store; different default). An element with no counterpart and no verdict in `tests/parity/overrides.csv` / `overrides-f2s.csv` fails, and so does a behaviour note without a verdict (`ok: <reason>` or `MISSING: P<n>`); a gap logged as `MISSING: P<n>` with P<n> open in `PARITY-GAPS.md` is KNOWN (fails only with `TBF_STRICT=1`). Android-only elements and Flutter menu entries matched only by label are report-only. Output in `$TBF_OUT/parity/` (`FLUTTER-TO-SCITER-PARITY.md`, `FLUTTER-PARITY-ELEMENTS.md`, CSVs). Presence only: "works" still needs the lab | Python, client source |
| `static-ui` | runs the real `res/inline-sciter.py` with a **non-UTF-8 platform default** and checks the embedded pages: correct UTF-8 and one script block per file; negative control: the 1.4.16 generator must fail | Python |
| `server-installer` | the server tarball's `install.sh` in a clean Ubuntu 24.04 container: fresh install, upgrade over a customised unit that pointed elsewhere (re-pointed, customisation kept, old binary replaced, `hbbs.env` untouched), `RESTART=1`, idempotency, custom prefix | podman + `localhost/nemo-gui` |
| `build-linux` | builds the Linux client used by the GUI stages | Rust |
| `sciter-parse` | loads the **exact page the release build embeds** into real libsciter: 0 script errors; negative control: the 1.4.16 page must fail with `Bad parse code` **and that error must land in the log file**; a `RUST_LOG` run mirrors the log to stderr | Xvfb, openbox, libsciter |
| `gui-linux` | real Linux client vs the lab server (also runs a PACKAGED client: `TBF_LINUX_BIN=<extracted pkg>/usr/share/rustdesk/rustdesk`, or `TBF_LINUX_DEB=<file.deb>` installed in an Ubuntu container), driven by clicks + OCR: registers (ID shown, never "Generating"), **⋮ menu opens, Settings opens**, script output in the log with no error, #43 report in sync | + lab hbbs, tesseract, xdotool |
| `session-linux` | both UIs (Sciter + Flutter) with 2 local monitors against a 2-display target: remote cursor in single/all/span/windows, screen/cursor/input delay, fps, CPU, RAM; keyboard (US + German with AltGr), 12 shortcuts, all mouse buttons, wheel, drag; cursor while a button is held; console session incl. refusal. ≈45 min, `--all` only. Accepted: Sciter-on-Linux horizontal wheel |
| `gui-windows-provision` | **unattended provisioning**, no GUI: clean uninstall (incl. the pre-rename RustDesk config) → a bad `--import-setup` exits 2 and installs nothing → `--silent-install --import-setup <file>` exits 0, the service holds this run's device key, the machine polls with it and #43 is in sync (confirmed *after* the run started) → output never contains the key → `Get-Content f \| TBFDesk.exe --import-setup -` re-provisions; no device key in the user's config → user opens the window: no key in any log (user, service, installer); the copy into the user's profile is reported **KNOWN (OPEN-TODOS #48)** | + VM |
| `gui-windows` | the **installer under test** on the Win11 VM: installs over the previous version, registers, **⋮ menu → Settings**, clean log, stderr mirroring, live log in the launching console, #43 in sync | + VM (`vmctl.sh start`) |
| `e2e-policy` | #43 end to end: assign policy A → row shows it applied; switch to B → follows; force a client-side **refusal** (rollback) → row shows *refused* + reason → recovers; dashboard badge in a headless browser | + VM with ≥1.4.18 |

## The 1.4.16 field bugs, and what now catches them

| Bug (Windows 1.4.16) | Root cause | Caught by |
|---|---|---|
| ⋮ menu did nothing; ID stuck on "Wird generiert…", status "Verbinden…" with a reachable server | release build packed all main-window scripts into ONE Sciter block; `index.tis` outgrew the per-block limit, everything after ~line 2707 never loaded | `unit-client` (one script block per file; size guard), `static-ui` (generated pages), `sciter-parse` (real libsciter, + negative control), `gui-linux` / `gui-windows` (clicks + OCR) |
| Garbled characters ("Einstellungen â€¦") | `inline-sciter.py` read UTF-8 files in the Windows code page | `unit-client` (every `open()` has `encoding='utf-8'`), `static-ui` (non-UTF-8 platform default + negative control) |
| A script failure left no trace in the log | sciter-rs printed script errors to a console the GUI exe does not have | `sciter-parse` (error must be in the log file), `gui-*` (log checks) |
| Starting the client from a shell showed no output | no console + log only in the file | `sciter-parse` (stderr mirroring), `gui-windows` (redirected stderr + live console) |

## Ubuntu 26.04 / Wayland field bugs (2026-11), and what catches them

Test cases (user steps, platform/UI matrix, check commands, status), the Ubuntu desktop VM recipe
and its traps: **[CROSS-PLATFORM-FIELD-TESTS.md](CROSS-PLATFORM-FIELD-TESTS.md)**. Why the suite
missed them: every Linux GUI stage runs on X11 (Xvfb / Xvnc + openbox), and none runs the per-user
`--server` inside a real GNOME Wayland session or uses its screen-share portal.

| Bug (Ubuntu 26.04, 1.4.21–1.4.23) | Root cause | Caught by |
|---|---|---|
| FT-01 Connect greyed ("outgoing connections disabled"), Windows fine; fixed 1.4.23 | a window save sent the whole option map over per-uid IPC, so a policy-only key got stored as a setting | `unit-client` (`a_window_save_never_stores_what_only_the_policy_may_set`); GUI manual |
| FT-02 blank Sciter main window (dev build, never released) | TIScript does not hoist: `App.render` called a function defined below `class App` | nothing proven yet. TODO: `sciter-parse` negative control with `9fcb5c2fe^`, plus a static "defined above `class App`" check |
| FT-03 clock 1 h ahead: policy refused silently | server refused sealed requests outside +60 s / −300 s; client policy age 600 s | `unit-client` (2 clock tests), `unit-server` (`the_clock_tolerance_is_symmetric_configurable_and_leaves_no_replay_gap`); GUI manual |
| FT-08 clipboard both ways | not reproduced (1.4.23 Sciter passes all 4 directions); GNOME needs the X11 fallback | manual; TODO script |
| FT-10 session window will not drag to monitor 2 | `window-frame="extended"` Sciter window runs native Wayland | manual (`uvm-lab.sh drag` + per-head shot); TODO script |
| FT-04–07, FT-09, FT-11, FT-12 | not yet investigated / open | manual cases in the file |

## Prerequisites (one-time)
- Rust toolchain; the client build env is in `tests/lib/client-env.sh` (clang, system libsodium, `pkgconfig/libyuv.pc`, a vcpkg for hwcodec).
- `Xvfb`, `openbox`, `xdotool`, ImageMagick `import`, `tesseract` with `vm/tessdata` (deu+eng), Python 3 + Pillow, `node`, `brave`.
- Lab server: `hbbs`/`hbbr` from `rustdesk-server-nemo/target/release`, data dir `vm/lab2`.
- Windows VM: `vm/scripts/vmctl.sh start`; the installer to test on the VM (built with `C:\src\build<ver>.cmd`, a copy of `scripts/vm-build-windows-client.cmd`; recipe in `HANDOFF.md`).

## Layout
```
tests/run-all.sh                       orchestrator
tests/lib/common.sh                    lab API, device keys, VM, result helpers
tests/lib/client-env.sh                Linux client build environment
tests/lib/ocr.py                       OCR: find UI text + coordinates in a screenshot
tests/contracts/                       cross-repo contract checks
tests/static/                          build-pipeline checks (no display)
tests/parity/inventory.py              Sciter <-> Flutter parity inventory (+ overrides*.csv verdicts)
tests/gui/sciter_parse.sh              libsciter parse + logging + mirroring
tests/gui/linux_client.sh              Linux GUI test (clicks + OCR)
tests/gui/windows_client.sh, win/      Windows VM GUI test + its PowerShell helpers
tests/gui/windows_provision.sh         Windows VM unattended install + provisioning (no GUI)
tests/e2e/policy_applied.sh            #43 end to end
```

## Writing a new GUI check
Find text with `tests/lib/ocr.py find <png> "Deutsch|English"` (German and English labels both
accepted); click its coordinates; assert with `ocr.py has`. Two traps learned the hard way: hover
before clicking (Sciter ignores a click on an element that has not seen the pointer), and never
leave one of our own windows (consoles) on top of the client while clicking.

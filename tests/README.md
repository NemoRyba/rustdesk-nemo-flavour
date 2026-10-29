# TBFDesk test suite

One command runs every automated check — Rust unit tests, cross-repo contract checks, the
UI build pipeline, and **real GUI tests that click through the client** on Linux (Xvfb) and on
the Win11 test VM, reading the screen with OCR and checking the logs.

```bash
tests/run-all.sh                 # unit + contract + static + Linux GUI        (default)
tests/run-all.sh --quick         # unit + contract + static only               (no display, no lab)
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
| `unit-client` | `cargo test --lib` of the client (130+ tests), incl. #43 report building and the server signature contract, and the **1.4.16 regression guards** (below) | Rust + `tests/lib/client-env.sh` |
| `contract` | client and server agree on the #43 report: every refusal code the client can send is one the server accepts; same signature domain; same fields | Python |
| `static-ui` | runs the real `res/inline-sciter.py` with a **non-UTF-8 platform default** and checks the embedded pages: correct UTF-8 and one script block per file; negative control: the 1.4.16 generator must fail | Python |
| `server-installer` | the server tarball's `install.sh` in a clean Ubuntu 24.04 container: fresh install, upgrade over a customised unit that pointed elsewhere (re-pointed, customisation kept, old binary replaced, `hbbs.env` untouched), `RESTART=1`, idempotency, custom prefix | podman + `localhost/nemo-gui` |
| `build-linux` | builds the Linux client used by the GUI stages | Rust |
| `sciter-parse` | loads the **exact page the release build embeds** into real libsciter: 0 script errors; negative control: the 1.4.16 page must fail with `Bad parse code` **and that error must land in the log file**; a `RUST_LOG` run mirrors the log to stderr | Xvfb, openbox, libsciter |
| `gui-linux` | real Linux client vs the lab server (also runs a PACKAGED client: `TBF_LINUX_BIN=<extracted pkg>/usr/share/rustdesk/rustdesk`, or `TBF_LINUX_DEB=<file.deb>` installed in an Ubuntu container), driven by clicks + OCR: registers (ID shown, never "Generating"), **⋮ menu opens, Settings opens**, script output in the log with no error, #43 report in sync | + lab hbbs, tesseract, xdotool |
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

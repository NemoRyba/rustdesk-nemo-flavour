# TBFDesk runbook for a local model

This runbook is for an assistant that follows steps literally.
Do the steps in order. Run one command per step.
After each command, compare the output with the "Expect" line.
If the output does not match, stop and look up the error in section 9 (Troubleshooting).
If section 9 does not list the error, stop and report the exact command and the exact output to the human.

A line that starts with `UNVERIFIED:` states something that the author could not confirm from the files.
Before you rely on an UNVERIFIED fact, check it with a command. If you cannot check it, ask the human.

All paths in this runbook are absolute. Do not change them.

Written 2026-09-27 from: the memory notes, `/projects/rustdesk/AGENTS.md`, the `rustdesk-vm-control` skill
(`/projects/rustdesk/.opencode/skills/rustdesk-vm-control/SKILL.md`), `/projects/rustdesk/vm/scripts/*`,
`DEPLOY.md`, `README.md`, `HANDOFF.md`, `scripts/*`, the server's `systemd/` units and `src/main.rs`,
and `/projects/rustdesk/vm/shots/CHECKLIST.md`.

## Contents

0. Paths and names
1. Hard rules
2. Build and test the server (hbbs, hbbr)
3. Build and test the Linux client (Arch)
4. Build the Windows client (inside the Win11 VM)
5. The loopback lab (hbbs + hbbr on this machine)
6. The Windows VMs
7. GUI control
8. Worked example: VM, copy client, launch, screenshot, click by label
9. Troubleshooting
10. List of UNVERIFIED items

---

## 0. Paths and names

| Name | Path or value |
|---|---|
| Superproject (branch `nemo-tdd`) | `/projects/rustdesk/rustdesk-nemo-flavour` |
| Client repo (submodule) | `/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo` |
| Server repo (submodule) | `/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo` |
| Client proto copy | `/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/libs/hbb_common/protos/` |
| Server proto copy | `/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/libs/hbb_common/protos/` |
| VM control entry point | `/projects/rustdesk/vm/scripts/vmctl.sh` |
| VM root | `/projects/rustdesk/vm` |
| Win11 disk | `/projects/rustdesk/vm/disks/win11.qcow2` |
| Win10 disk | `/projects/rustdesk/vm/disks/win10.qcow2` |
| Sciter runtime for Linux | `/projects/rustdesk/vm/lib/libsciter-gtk.so` |
| Sciter runtime for Windows | `/projects/rustdesk/rustdesk-nemo-flavour/downloads/sciter-x64/sciter.dll` |
| Last known Windows client build (2026-09-20, older than HEAD) | `/projects/rustdesk/vm/artifacts/tbfdesk-windows-x64.exe` |
| vcpkg tree for Linux `hwcodec` | `/home/nemo/.cache/yay/rustdesk/src/vcpkg-120deac3062162151622ca4860575a33844ba10b` |
| CPU pin list (always) | `0-3,6,7,10,11,14-31` |
| Faulty logical CPUs (never use) | `4,5,8,9,12,13` |
| Screenshots folder | `/projects/rustdesk/vm/shots/` |
| Windows VM login user | `tbf` |
| Guest folder for the client | `C:\tbf-new` |
| Guest client config | `C:\Users\tbf\AppData\Roaming\RustDesk\config\RustDesk2.toml` |
| Host address as seen from the guest | `10.0.2.2` |

Client crate version: `rustdesk v1.4.7`. Server crate version: `hbbs 1.1.15`.

### 0.1 Check that you are on the right code

Step 0.1.1. Check the superproject branch.
```sh
git -C /projects/rustdesk/rustdesk-nemo-flavour branch --show-current
```
Expect: `nemo-tdd`

Step 0.1.2. Check the client branch.
```sh
git -C /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo branch --show-current
```
Expect: `nemo-tdd`

Step 0.1.3. Check the server branch.
```sh
git -C /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo branch --show-current
```
Expect: `nemo-tdd`

If any step prints `master`, stop. `master` is a stale May 2026 snapshot. Ask the human.

Step 0.1.4. Check that the faulty CPUs are offline.
```sh
cat /sys/devices/system/cpu/offline
```
Expect: `4-5,8-9,12-13`
If the output is empty, the faulty CPUs are online. That makes rule 1 even more important. Tell the human.

---

## 1. Hard rules

1. **Pin every build, test and long-running program to the good CPUs.** Put `taskset -c 0-3,6,7,10,11,14-31` in front of every `cargo`, every build script, every `hbbs`/`hbbr` you start and every `vmctl.sh start`. Logical CPUs 4,5,8,9,12,13 are faulty i9 P-cores. They produce wrong results and have frozen the whole machine. Evidence: `/projects/crash/RMA-EVIDENCE.md`. Also pass `-j 12` to cargo (or set `CARGO_BUILD_JOBS=12`). Never use more.
2. **Never run `pkill -f`.** The pattern also matches your own shell's command line and kills it. This has happened four times. To stop a process, use its PID: `kill <pid>`. To find a PID, read `/proc/<pid>/exe`, or use the PID that `$!` printed when you started it. `pgrep -x <exact-name>` is also safe.
3. **Never push to a remote.** Do not run `git push` unless the human says yes in this conversation. Do not commit unless the human asks for a commit.
4. **Never commit runtime files.** Never commit `db_v2.sqlite3` (it is tracked in the server repo and is modified by every run: `git status` shows ` M db_v2.sqlite3` — leave it). Never commit `id_ed25519`, `id_ed25519.pub`, `*.log`, `nemo_integration.json`, certificates, `src/version.rs`, or anything under `target/`. Never run `git add -A` or `git add .`. Add each file by its path: `git add src/some_file.rs`.
5. **Keep the two hbb_common protos in step.** The files are `libs/hbb_common/protos/rendezvous.proto` and `libs/hbb_common/protos/message.proto`, in the client repo and in the server repo. If you change a `.proto` in one repo, make the byte-identical change in the other repo. Check with the commands in 1.1.
6. **Do not edit `src/ui/inline.rs`.** It is gitignored and generated. The source of truth for the Sciter UI is `src/ui/index.tis` (and the other files in `src/ui/`). To regenerate `inline.rs`, run `python3 res/inline-sciter.py` from the client repo root.
7. **A claim is verified only by command output you saw yourself.** "Tests pass" is verified only when you ran the test command in this session and the output contains a line like `test result: ok. 77 passed; 0 failed`. Copy that exact line into your report. A summary, a document, another agent's message, or an empty output is not verification. Empty output is not success: check the exit code with `echo "exit=$?"`.
8. **Start every VM task with `/projects/rustdesk/vm/scripts/vmctl.sh status`.** Never type a forwarded port number from memory, from an old log, or from this runbook. Read it from `status` every time.
9. **Never repeat a failing command unchanged.** If a command fails, read the error, change the cause or the method, then try once more. If it fails the same way again, stop and report.
10. **Do not suppress stderr** (no `2>/dev/null`) while you diagnose a problem.
11. **Do not start or stop the VM, the lab containers, or `lab-down.sh`, unless the task needs it.** Other work may be using them. `lab-down.sh` stops the VM, every container, every `target/release/rustdesk`, every `hbbr` and every `Xvfb` on the machine.
12. **Only one heavy build at a time.** Before a build, run `pgrep -x cargo`. If it prints PIDs, another build is running. Wait for it to finish (see 9, "Blocking waiting for file lock").
13. **Check the premise before you fix anything.** Before writing a fix, prove the problem exists with a command, and paste the output into your report. Example: before "hardening" a socket you think is world-writable, run `ls -la /tmp/RustDesk-$(id -u)/`. In September 2026 a fix was committed for a socket that was already `srw-------`; it protected nothing and broke `sudo tbfdesk --option ...`, so it was reverted.
14. **Test a change from the other side too.** If you change what the server sends, read the code that consumes it (for the admin page, `src/nemo_admin.html`) and check the field names match. In September 2026 the server returned a bare map while the page read `result.permissions`, and the page lost its whole allowlist after every save. When you can, run hbbs on loopback and use `curl` to prove the round-trip (section 5.1).
15. **Do not write "done", "fixed" or "pushed" in a document unless you proved it in this session.** Name the commit that did it. Do not move old work under a new date.

### 1.1 Proto check

Step 1.1.1. Compare the rendezvous protos.
```sh
cmp /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/libs/hbb_common/protos/rendezvous.proto /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/libs/hbb_common/protos/rendezvous.proto && echo IDENTICAL
```
Expect: `IDENTICAL`

Step 1.1.2. Compare the message protos.
```sh
cmp /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/libs/hbb_common/protos/message.proto /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/libs/hbb_common/protos/message.proto && echo IDENTICAL
```
UNVERIFIED: whether this pair is meant to be identical. On 2026-09-27 it was NOT identical (the client copy has newer upstream fields such as `Terminal`, `is_resume`, `CliprdrFile`; first difference at line 82). `rendezvous.proto` was identical.
Rule: run 1.1.1 and 1.1.2 before you edit anything and write down the result. Run them again after your edit. The result must not get worse. Do not try to "fix" the `message.proto` difference yourself. Ask the human.

---

## 2. Build and test the server (hbbs, hbbr)

The server repo builds three binaries: `hbbs` (signal/rendezvous server + management API), `hbbr` (relay), `rustdesk-utils`.
Default features: `nemo-management-api`, `nemo-ldap`, `nemo-tls`.

### 2.1 Run the server tests

Step 2.1.1. Check that no other cargo is running.
```sh
pgrep -x cargo
```
Expect: no output. If PIDs are printed, wait (rule 12).

Step 2.1.2. Run the tests (known-good command). Give it a timeout of at least 30 minutes.
```sh
cd /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo && taskset -c 0-3,6,7,10,11,14-31 cargo test -j 12 2>&1 | tee /tmp/server-test.log | grep -E '^test result|FAILED|panicked|^error'
```
Expect (the first line is the library tests; the count may be higher than 82, updated 2026-09-28):
```
test result: ok. 82 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in ...
test result: ok. 2 passed; 0 failed; ...
test result: ok. 0 passed; 0 failed; ...
test result: ok. 0 passed; 0 failed; ...
test result: ok. 0 passed; 0 failed; ...
```
Pass condition: every `test result:` line says `ok` and `0 failed`, and the first line says 82 or more passed.
Warnings (`warning: unused return value ...`) are normal.

### 2.2 Build the server binaries

Step 2.2.1. Release build (command from `DEPLOY.md`, with the CPU pin added).
```sh
cd /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo && SODIUM_LIB_DIR=/usr/lib SODIUM_SHARED=1 ZSTD_SYS_USE_PKG_CONFIG=1 taskset -c 0-3,6,7,10,11,14-31 cargo build --release -j 12 2>&1 | tail -3
```
Expect a last line like: `Finished `release` profile [optimized] target(s) in ...`

Step 2.2.2. Check the binaries exist.
```sh
ls -la /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/target/release/hbbs /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/target/release/hbbr
```
Expect: two lines, both files executable (`-rwxr-xr-x`).

Step 2.2.3. Check the version.
```sh
/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/target/release/hbbs --version
```
Expect: `hbbs 1.1.15`

Where binaries land:
- `cargo build --release` → `/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/target/release/{hbbs,hbbr,rustdesk-utils}`
- `cargo build` (debug) → `/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/target/debug/{hbbs,hbbr,rustdesk-utils}` (the `h9-lab.sh` lab uses the debug ones)
- The relay probe example (`examples/relayprobe.rs`) is not in release builds. It lands in `target/debug/examples/relayprobe` after `cargo build --examples`.

Step 2.2.4 (optional, only if the task asks for a container image). Build the container image from the release binaries.
```sh
taskset -c 0-3,6,7,10,11,14-31 /projects/rustdesk/rustdesk-nemo-flavour/scripts/build-server-container.sh
```
Expect last lines: `Built localhost/nemo-hbbs:<version> (profile: release), also tagged :latest.`

---

## 3. Build and test the Linux client (Arch)

### 3.1 Run the client tests

Step 3.1.1. Check that no other cargo is running.
```sh
pgrep -x cargo
```
Expect: no output.

Step 3.1.2. Run the library tests (known-good command). Give it a timeout of at least 60 minutes (a cold build is long).
```sh
cd /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo && VCPKG_ROOT=/home/nemo/.cache/yay/rustdesk/src/vcpkg-120deac3062162151622ca4860575a33844ba10b PKG_CONFIG_PATH=/projects/rustdesk/rustdesk-nemo-flavour/pkgconfig taskset -c 0-3,6,7,10,11,14-31 cargo test --release --features linux-pkg-config,hwcodec -j 12 --lib 2>&1 | tee /tmp/client-test.log | grep -E '^test result|FAILED|panicked|^error'
```
Expect:
```
test result: ok. 86 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in ...
```
Pass condition: `ok`, `0 failed`, 86 or more passed.

### 3.2 Build a runnable Linux client

The build script checks pacman packages, sets `CC=clang`, `SODIUM_LIB_DIR=/usr/lib`, `SODIUM_SHARED=1`, `OPENSSL_NO_VENDOR=1`, prepends the workspace `pkgconfig/`, finds `VCPKG_ROOT` by itself, and builds with features `linux-pkg-config,hwcodec`.

Step 3.2.1. Build the release client.
```sh
CARGO_BUILD_JOBS=12 taskset -c 0-3,6,7,10,11,14-31 /projects/rustdesk/rustdesk-nemo-flavour/scripts/build-arch-client.sh --release 2>&1 | tail -3
```
Expect, as the last line:
```
Built: /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/target/release/rustdesk (features: linux-pkg-config,hwcodec)
```
Also expect, earlier: `hwcodec: using VCPKG_ROOT=/home/nemo/.cache/yay/rustdesk/src/vcpkg-120deac...`
If you see `Missing packages: ...`, stop and ask the human to install them (needs sudo).

Note: the build script sets `CC=clang`; the test command in 3.1.2 does not. Switching between them may rebuild C dependencies. That is slow but not an error.

Step 3.2.2. Check the binary.
```sh
ls -la /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/target/release/rustdesk
```
Expect: one executable file.

Always use a **release** build for GUI runs. A debug build panics in rust-sciter's window-flag code.
On Linux the `inline` feature is not used: the client reads `src/ui/*.html/*.tis/*.css` at run time, relative to the current directory. So always start it **from the client repo root**. A `.tis` change needs a restart, not a rebuild.

### 3.3 Run the Linux client headless (no real display touched)

Step 3.3.1. See which X displays exist.
```sh
ls /tmp/.X11-unix/
```
If `X99` is listed, an Xvfb on `:99` is already running. Use it (the `lab*` scripts only work on `:99`). If `X99` is not listed, do step 3.3.2.

Step 3.3.2. Start Xvfb on `:99`.
```sh
nohup taskset -c 0-3,6,7,10,11,14-31 Xvfb :99 -screen 0 1400x900x24 -nolisten tcp > /tmp/xvfb99.log 2>&1 & echo "xvfb pid $!"
```
Expect: `xvfb pid <number>`. Write the number down.

Step 3.3.3. Start the client with a durable HOME. Pick a NEW home name so you do not change an existing lab identity (for example `llm-home`).
```sh
taskset -c 0-3,6,7,10,11,14-31 /projects/rustdesk/vm/scripts/run-lab-client.sh llm-home :99
```
Expect: `launched pid <number> HOME=/projects/rustdesk/vm/lab-clients/llm-home DISPLAY=:99`
The log is `/projects/rustdesk/vm/lab-clients/llm-home.log`.
Existing home names (do not reuse without the human's ok): `arch-home`, `cli-home`, `fix-home`, `visual-home`, `ubuntu-home`, `peer2-home` … `peer7-home`.

Step 3.3.4. Take a screenshot.
```sh
/projects/rustdesk/vm/scripts/labshot.sh /projects/rustdesk/vm/shots/llm-linux-1.png
```
Expect: `saved /projects/rustdesk/vm/shots/llm-linux-1.png (<W>x<H>)`
The build id (git hash + date) is shown bottom-left in the window.

---

## 4. Build the Windows client (inside the Win11 VM)

Facts from the memory notes (built and verified 2026-09-20):
- The build runs **inside the Win11 VM**, driven over SSH. Cross-compiling from Linux is not supported.
- Features: `--features inline,hwcodec,vram`. The result was a 48.8 MB `rustdesk.exe`.
- Toolchain in the guest under `C:\build\tools`: Rust MSVC (rustup), VS Build Tools 2022 C++ workload, Windows SDK, LLVM 15.0.6, Python, git, nasm, vcpkg at commit `120deac3062...` with `--triplet x64-windows-static libvpx aom libyuv opus ffmpeg mfx-dispatch`.
- Environment: run inside `vcvars64.bat`; `VCPKG_ROOT=C:\build\tools\vcpkg`; `LIBCLANG_PATH=<...>\llvm-15.0.6\bin`.
- `.cargo/config.toml` already forces `+crt-static`, so vcpkg picks `x64-windows-static` by itself.
- The superproject script `build-run-windows-client.ps1` expects `tools\vcpkg-120deac` and `tools\llvm-15.0.6` next to it (gitignored). It is for a Windows workstation checkout, not for this VM.
- UNVERIFIED: the exact guest folder of the client source. The steps below use `C:\build\rustdesk-client-nemo`.
- UNVERIFIED: the exact paths of `vcvars64.bat` and of LLVM in the guest. Steps 4.2 and 4.3 find them.
- UNVERIFIED: `README.md` says Rust 1.75 is required for the Sciter bindings. The Rust version used for the 2026-09-20 VM build is not recorded.

### 4.1 Make sure the VM is up

Step 4.1.1.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh status
```
Expect: `state=running` and a last line `ssh=ready`. If not, do section 6.2 first.

### 4.2 Find the toolchain in the guest

Step 4.2.1. List the tools folder.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps 'Get-ChildItem C:\build\tools | Select-Object -ExpandProperty Name'
```
Expect: names that include a vcpkg folder and an llvm-15.0.6 folder. Write the exact names down.

Step 4.2.2. Find `libclang.dll` (its folder is `LIBCLANG_PATH`).
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps 'Get-ChildItem C:\build\tools -Recurse -Filter libclang.dll -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DirectoryName'
```
Expect: one folder path ending in `\bin`. Write it down as LIBCLANG_PATH.

### 4.3 Find vcvars64.bat

Step 4.3.1.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps 'Get-ChildItem "C:\Program Files (x86)\Microsoft Visual Studio","C:\Program Files\Microsoft Visual Studio" -Recurse -Filter vcvars64.bat -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName'
```
Expect: one full path ending in `\vcvars64.bat`. Write it down as VCVARS.

### 4.4 Generate inline.rs on the host

Python in the guest did not install (gotcha 4), so generate the inline UI on the host. This regenerates a gitignored file; it is not a hand edit.

Step 4.4.1.
```sh
cd /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo && python3 res/inline-sciter.py; echo "exit=$?"
```
Expect: `exit=0`

Step 4.4.2.
```sh
ls -la /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/src/ui/inline.rs
```
Expect: the file exists and its time is now.

Repeat 4.4 every time any file in `src/ui/` changes. Without it the Windows build shows the old UI.

### 4.5 Copy the client source into the guest

Step 4.5.1. Pack the source without `target/` and without `.git`.
```sh
tar -C /projects/rustdesk/rustdesk-nemo-flavour --exclude='rustdesk-client-nemo/target' --exclude='.git' -czf /tmp/client-src.tgz rustdesk-client-nemo; echo "exit=$?"
```
Expect: `exit=0`

Step 4.5.2. Upload it.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh put /tmp/client-src.tgz 'C:/build/client-src.tgz'
```
Expect: no output and exit code 0 (check with `echo "exit=$?"`).

Step 4.5.3. Unpack it in the guest (Windows 10/11 ships `tar.exe`).
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ssh 'cd /d C:\build && tar -xzf client-src.tgz && dir C:\build\rustdesk-client-nemo\src\ui\inline.rs'
```
Expect: a `dir` listing that shows `inline.rs`.

The build id will show "Build unknown" because there is no `.git`. That is expected.

### 4.6 Build in the guest

The build is long (the release profile uses LTO; about 7 minutes on a warm cache, much longer cold). Run the SSH session in the background on the host and poll the log.

Step 4.6.1. Start the build. Replace `<VCVARS>` with the path from 4.3.1 and `<LIBCLANG_PATH>` with the path from 4.2.2. Replace `<VCPKG>` with the vcpkg folder from 4.2.1 (the memory note says `C:\build\tools\vcpkg`).
```sh
nohup /projects/rustdesk/vm/scripts/vmctl.sh ssh 'call "<VCVARS>" && set "VCPKG_ROOT=<VCPKG>" && set "LIBCLANG_PATH=<LIBCLANG_PATH>" && cd /d C:\build\rustdesk-client-nemo && %USERPROFILE%\.cargo\bin\cargo.exe build --release --features inline,hwcodec,vram' > /tmp/winbuild.log 2>&1 & echo "ssh pid $!"
```
Expect: `ssh pid <number>`.
The VM's CPUs are the QEMU process's CPUs. Check that QEMU is pinned (step 6.2.4).

Step 4.6.2. Poll the log (repeat every few minutes).
```sh
tail -n 5 /tmp/winbuild.log
```
Done when a line says `Finished `release` profile`. Failed when a line starts with `error`.

Step 4.6.3. Check the result.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ssh 'dir C:\build\rustdesk-client-nemo\target\release\rustdesk.exe'
```
Expect: `rustdesk.exe`, size about 48 MB.

Step 4.6.4 (optional). Copy the exe back to the host.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh get 'C:/build/rustdesk-client-nemo/target/release/rustdesk.exe' /projects/rustdesk/vm/artifacts/tbfdesk-windows-x64-new.exe
```

### 4.7 Windows build gotchas (all were hit for real)

1. `winget` is missing (Enterprise Eval). Download installers directly. The guest has internet, but Windows Update is blocked, so `Add-WindowsCapability` fails.
2. VS Build Tools does not install the Windows SDK with `--add ...Windows11SDK.22000` (silently skipped). Fix: run the standalone `winsdksetup.exe` with `/features +`. Without the SDK, `rc.exe`/`mt.exe` are missing and vcpkg ports fail at cmake config (`CMAKE_MT-NOTFOUND`, RC "no such file").
3. vcpkg must run inside `vcvars64.bat`, or `rc`/`mt` are not found even with the SDK.
4. The Python MSI silently did not install. Generate `src/ui/inline.rs` on the host (4.4) and copy it in. Without it: `error[E0583]` for `mod inline;` at `src/ui.rs`.
5. `hwcodec` link gaps: it needs `libmfx.lib` (vcpkg port `mfx-dispatch`, not `intel-media-sdk`), `libswresample` (`swr_*`), and `mfuuid`/`strmiids` (`IID_ICodecAPI`, `IID_IMFTransform`). The fix is committed: `rustdesk-client-nemo/build.rs` `build_windows()` links swresample/swscale/mfuuid/strmiids/mfplat when `hwcodec` is on. If these errors return, check that `build.rs` still has that code.

---

## 5. The loopback lab (hbbs + hbbr on this machine)

There are three labs. Use 5.1 unless the task names another one.
- 5.1 Native loopback lab: fresh hbbs + hbbr from `target/release`, in an empty folder. For API and client tests.
- 5.2 The container QA lab: `lab-up.sh` / `lab-down.sh`. Long-lived state. Ask the human before you start or stop it.
- 5.3 The policy-gate lab: `h9-lab.sh` on ports 318xx.

### 5.0 Server flags and environment (reference)

Production unit `rustdesk-server-nemo/systemd/rustdesk-hbbs-nemo.service`:
```
User=rustdesk  Group=rustdesk  WorkingDirectory=/var/lib/rustdesk-server
EnvironmentFile=/etc/tbfdesk/hbbs.env
ExecStart=/usr/bin/hbbs -r ${TBFDESK_RELAY} --mask ${TBFDESK_MASK} -k _ --nemo-api Y --nemo-api-bind 0.0.0.0:21120 --nemo-api-tls auto
logs: /var/log/rustdesk-server/hbbs.log and hbbs.error
```
Environment file `/etc/tbfdesk/hbbs.env` (mode 0600, owner root:rustdesk):
```
NEMO_API_TOKEN=<the admin token>
TBFDESK_RELAY=<server>:21117
TBFDESK_MASK=192.168.0.0/16
```
hbbs reads every flag also from an environment variable with the same name in upper case (`NEMO_API_TOKEN` = `--nemo-api-token`). Put the token in the env file, never in `ExecStart` (argv is world-readable).

Production unit `rustdesk-hbbr-nemo.service`: `ExecStart=/usr/bin/hbbr -k _`, same user and folder.
Drop-in `rustdesk-hbbr-nemo.service.d/override.conf`: `SINGLE_BANDWIDTH=10000`, `TOTAL_BANDWIDTH=10000`, `LIMIT_SPEED=10000` (Mb/s).

All hbbs flags (from `rustdesk-server-nemo/src/main.rs`):

| Flag | Default | Meaning |
|---|---|---|
| `-c, --config` | | config file |
| `-p, --port` | 21116 | rendezvous port (NAT test port = port-1, i.e. 21115) |
| `-s, --serial` | 0 | config update serial |
| `-R, --rendezvous-servers` | | other rendezvous servers |
| `-u, --software-url` | | download URL of newest client |
| `-r, --relay-servers` | | relay list. Must be a ROUTABLE address, never 127.0.0.1 |
| `-M, --rmem` | 0 | UDP receive buffer |
| `--mask` | | LAN range, e.g. `192.168.0.0/16` |
| `-k, --key` | | `_` = use `id_ed25519` in the working folder (created if missing) |
| `--udp-registration` | N | plaintext UDP registration. Keep N |
| `--key-exchange` | require | `off` / `offer` / `require`. `off` is for debugging only |
| `--nemo-api` | N | enable the management API |
| `--nemo-api-bind` | 127.0.0.1:21120 | API address |
| `--nemo-api-token` | | admin bearer token (required on a non-loopback bind) |
| `--nemo-api-tls` | | `auto` (self-signed) or `off`. TLS is on by default for a routable bind |
| `--nemo-api-tls-cert`, `--nemo-api-tls-key` | | PEM files |
| `--nemo-api-cert-file`, `--nemo-api-key-file` | | where the self-signed cert/key are stored |
| `--nemo-api-allow-insecure` | N | allow plain HTTP on a routable bind (lab only) |
| `--nemo-integration-file` | | LDAP + RBAC JSON |
| `--insecure-ldap-i-accept-mitm` | N | lab only |
| `--allow-unbound-device-keys` | N | lab only |
| `--nemo-global-policy-file` | | global client policy JSON |
| `--nemo-company-only-file` | | persists the company-only flag |
| `--nemo-company-only` | N | only explicitly allowed peers are targets |

hbbr flags: `-k, --key` and `-p, --port` (default 21117).

Ports: 21115 NAT test + loopback command port, 21116 rendezvous TCP/UDP, 21117 relay, 21118/21119 websocket (refused by this fork), 21120 management API + admin UI.

Where keys live:
| Setup | Private key | Public key |
|---|---|---|
| Any hbbs/hbbr started with `-k _` | `id_ed25519` in its working folder | `id_ed25519.pub` in the same folder |
| Production | `/var/lib/rustdesk-server/id_ed25519` | `/var/lib/rustdesk-server/id_ed25519.pub` |
| Container lab `nemo-server` | podman volume `nemo-server-data`, file `/srv/id_ed25519` | public key `PY+BPqyx9GjeNfk9+nticI84Pk2oujmYQX0MtUaVcrE=` |
| Host relay of the container lab | `/projects/rustdesk/vm/relay/id_ed25519` (a copy of the server key) | `/projects/rustdesk/vm/relay/id_ed25519.pub` |
| Backup of old container state | `/projects/rustdesk/vm/server-state-backup/` (DB needs its `-wal` file) | |

hbbs and hbbr must use the SAME key. Starting both in the same folder with `-k _` does that. Start hbbs FIRST: since 2026-09-27 a missing `id_ed25519` is fatal. hbbs creates one only with `--generate-key Y` (lab only, never on production: clients pin the key); hbbr never creates one and exits until the file exists.

### 5.1 Native loopback lab

Step 5.1.1. Check that the ports are free.
```sh
ss -ltnp | grep -E ':(2111[5-9]|21120) '
```
Expect: no output. If there is output, another server is using the ports (probably the container lab). Stop and ask the human, or use that server instead.

Step 5.1.2. Make an empty folder.
```sh
mkdir -p /tmp/tbf-lab && ls -A /tmp/tbf-lab
```
Expect: no output (empty). If it is not empty, use a new name such as `/tmp/tbf-lab2` and use that name in every step below.

Step 5.1.3. Find the routable host address (for the relay).
```sh
ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}'
```
Expect: an address like `192.168.x.y`. Write it down as HOSTIP. Never use 127.0.0.1 for the relay: hbbr treats every loopback connection as its command port and nothing pairs.

Step 5.1.4. Start hbbs. Replace `<HOSTIP>`.
```sh
cd /tmp/tbf-lab && nohup taskset -c 0-3,6,7,10,11,14-31 /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/target/release/hbbs -k _ --generate-key Y -r <HOSTIP>:21117 --nemo-api Y --nemo-api-bind 127.0.0.1:21120 --nemo-api-token labtoken --nemo-api-allow-insecure Y --key-exchange offer > /tmp/tbf-lab/hbbs.log 2>&1 & echo "hbbs pid $!"
```
Expect: `hbbs pid <number>`. Write the number down.

Step 5.1.5. Check the hbbs log.
```sh
grep -E 'key|Listening|management API' /tmp/tbf-lab/hbbs.log
```
Expect lines containing:
```
Private/public key written to id_ed25519/id_ed25519.pub
Listening on tcp/udp :21116
Listening on tcp :21115, extra port for NAT test
Nemo management API listening on http://127.0.0.1:21120
```
If the log is still empty, wait 3 seconds and run the step again (once).

Step 5.1.6. Start hbbr in the SAME folder (so it uses the same key).
```sh
cd /tmp/tbf-lab && nohup taskset -c 0-3,6,7,10,11,14-31 /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo/target/release/hbbr -k _ > /tmp/tbf-lab/hbbr.log 2>&1 & echo "hbbr pid $!"
```
Expect: `hbbr pid <number>`. Write it down.

Step 5.1.7. Check the hbbr log.
```sh
grep Listening /tmp/tbf-lab/hbbr.log
```
Expect: `Listening on tcp :21117` (and a websocket line).

Step 5.1.8. Read the server public key (clients need it as `key`).
```sh
cat /tmp/tbf-lab/id_ed25519.pub; echo
```
Expect: one base64 string, 44 characters.

Step 5.1.9. Check the management API.
```sh
curl -sS -H 'Authorization: Bearer labtoken' http://127.0.0.1:21120/nemo/api/health
```
Expect: a JSON object with the server settings.

Step 5.1.10. Admin UI. Open `http://127.0.0.1:21120/nemo/admin` in a browser and enter the token `labtoken`. The page is titled TBFDesk Admin.
For scripted tests, use curl (5.1.11–5.1.14). A headless-browser driver exists: `/projects/rustdesk/vm/scripts/cdp.mjs eval|click|type|shot|goto` (needs a Chromium/Brave with `--remote-debugging-port=9222`). UNVERIFIED: the exact Brave launch command used before.

Step 5.1.11. List peers.
```sh
curl -sS -H 'Authorization: Bearer labtoken' http://127.0.0.1:21120/nemo/api/peers
```
Expect: JSON (an empty list on a fresh server).

Step 5.1.12. Mint a device key for a peer id. Replace `<ID>` with the client's id.
```sh
curl -sS -X POST -H 'Authorization: Bearer labtoken' -H 'Content-Type: application/json' -d '{"label":"llm-test","peer_id":"<ID>"}' http://127.0.0.1:21120/nemo/api/device-keys
```
Expect: JSON with `id`, `label`, `public_key`, `private_key`, `created_at`, `peer_id`. The `private_key` is what the client imports as `nemo-device-key`.

Step 5.1.13. Allow a peer (makes it controllable). Replace `<ID>`.
```sh
curl -sS -X POST -H 'Authorization: Bearer labtoken' http://127.0.0.1:21120/nemo/api/peers/<ID>/allow
```
Other peer actions: `.../peers/<ID>/block`, `.../peers/<ID>/reset-policy`, `.../peers/<ID>/delete`, and `POST /nemo/api/peers/delete` with body `{"ids":["<ID>"]}`.

Step 5.1.14. Toggle device-key enforcement.
```sh
curl -sS -X PUT -H 'Authorization: Bearer labtoken' -H 'Content-Type: application/json' -d '{"require_device_key":true}' http://127.0.0.1:21120/nemo/api/policy
```

Step 5.1.15. Stop the lab. Use the two PIDs you wrote down.
```sh
kill <hbbs pid> <hbbr pid>
```
Step 5.1.16. Check the ports are free again.
```sh
ss -ltnp | grep -E ':(2111[5-9]|21120) '
```
Expect: no output.

#### Point a Linux client at the loopback lab

UNVERIFIED as a whole: these values are adapted from `/projects/rustdesk/vm/scripts/run-peer-container.sh` and `h9-lab.sh`, which use other addresses.
Write this file BEFORE the first start of a NEW home (step 3.3.3). File: `/projects/rustdesk/vm/lab-clients/llm-home/.config/rustdesk/RustDesk2.toml`. Replace `<HOSTIP>` and `<PUBKEY>` (from 5.1.8):
```toml
rendezvous_server = '127.0.0.1:21116'
nat_type = 2
serial = 0

[options]
custom-rendezvous-server = '127.0.0.1'
relay-server = '<HOSTIP>:21117'
api-server = 'http://127.0.0.1:21120'
key = '<PUBKEY>'
nemo-management-server = 'http://127.0.0.1:21120'
nemo-management-public-key = '<PUBKEY>'
nemo-management-enabled = 'Y'
allow-insecure-tls-fallback = 'Y'
```
Then: start the client (3.3.3), read its id from the window or with
`cd /projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo && HOME=/projects/rustdesk/vm/lab-clients/llm-home XDG_CONFIG_HOME=/projects/rustdesk/vm/lab-clients/llm-home/.config ./target/release/rustdesk --get-id`,
mint a key (5.1.12), and import it in the GUI with the button **Geräteschlüssel importieren** (there is no CLI path; `--option nemo-device-key` is refused on purpose). `run-peer-container.sh` instead writes `nemo-device-key = '<private_key>'` into `[options]` before start.

From the Windows VM, the host is `10.0.2.2` (use `10.0.2.2` instead of `127.0.0.1` in the guest config). The relay must still be `<HOSTIP>:21117`.

### 5.2 The container QA lab (ask the human first)

- Start: `taskset -c 0-3,6,7,10,11,14-31 /projects/rustdesk/vm/scripts/lab-up.sh`
- Stop: `/projects/rustdesk/vm/scripts/lab-down.sh` — stops the VM, all containers, the relay, every `target/release/rustdesk` and every Xvfb. It deletes nothing.
- hbbs runs in container `nemo-server` (image `localhost/nemo-hbbs`, volume `nemo-server-data:/srv`) with: `hbbs -k _ --nemo-api Y --nemo-api-bind 0.0.0.0:21120 --nemo-api-token labtoken --nemo-api-allow-insecure Y --key-exchange offer -r 169.254.1.2`, published ports 21115, 21116 tcp+udp, 21118, 21120.
- hbbr runs on the HOST: `/projects/rustdesk/vm/bin-hbbr -k _ -p 21117`, working folder `/projects/rustdesk/vm/relay/`, log `/projects/rustdesk/vm/logs/hbbr.log`. Do not publish 21117/21119 from the container.
- Admin UI: `http://127.0.0.1:21120/nemo/admin`, token `labtoken`.
- Check: `curl -sS -H 'Authorization: Bearer labtoken' http://127.0.0.1:21120/nemo/api/peers`
- Never `podman rm nemo-server` without the human: the volume keeps the key, but a removed container must be recreated with the exact command in `lab-up.sh`.
- Change the relay list live (no restart), from inside the container, over the loopback command port:
  `podman exec nemo-server bash -c 'exec 3<>/dev/tcp/127.0.0.1/21115; printf "rs <HOSTIP>\n" >&3; cat <&3'`
  Do not send `aur Y`: it also overwrites the relay list with "Y" (known server bug SRV-BUG-1).

### 5.3 The policy-gate lab

`/projects/rustdesk/vm/scripts/h9-lab.sh up|probe|down` starts hbbs (31815), hbbr (31819), API `http://127.0.0.1:31820` (token `labtoken`) and one debug client, all from `target/debug`, in `/tmp/h9lab`. It stops its own processes safely with `down`.
On 2026-09-27 this lab was running (ports 31814–31821 were listening). Check with `ss -ltnp | grep ':318'` before you start it.

### 5.4 Two-peer connect / port-forward test (a real controller and a real controlled machine)

Built and verified live on 2026-09-28. This is slower and more failure-prone than it
looks; every gotcha below was hit for real in this session. Use the `nemo-peer2` /
`nemo-peer3` containers (`vm/lab-clients/peer2-home`, `peer3-home` are bind-mounted to
`/home/peer` inside them, and `/client` inside each is a **live, read-only bind mount**
of `rustdesk-client-nemo` — a fresh host build is already the binary the container runs,
no copy needed).

1. **Do not run two clients as the same HOME on the bare host.** The main IPC socket is
   `/tmp/RustDesk-<uid>/ipc`, keyed by UID only, not by `$HOME`. Two `rustdesk` processes
   as the same Linux user will silently merge into one logical instance no matter what
   `$HOME`/`$XDG_CONFIG_HOME` you give them. Always use two containers, two VMs, or two
   different real users for a controller+controlled pair.
2. `podman start nemo-peer2 nemo-peer3` (they use the `nemolab` bridge, so they reach
   each other directly; `169.254.1.2` from inside either one reaches the HOST's own
   published/listening ports — `nemo-api-bind`'s loopback-only bind is the one exception,
   it is NOT reachable this way).
3. Give each container's home a `RustDesk2.toml` (see 0.1's config shape) with
   `custom-rendezvous-server = '<host-ip-or-169.254.1.2>:<PORT>'` — **the port is
   mandatory** if it is not 21116; without it the client silently uses the compiled-in
   default port and connects to the wrong (or no) server.
4. Provision a **bound** device key for each: `POST /nemo/api/device-keys` with
   `{"label":"...", "peer_id":"<the peer's TBFDesk id>"}` (you only learn the id after
   the FIRST connect with an unbound key or by reading it off the GUI) — an unbound key
   is refused once you also need it as a controller.
5. Start the controlled side as an ordinary GUI client (`Xvfb` + the plain binary, no
   flags). Screenshot it (`import -window <id>`) to read its **ID** and current
   **one-time password** — both are plain text on the first screen.
6. **The controller must ALSO be a persistent, already-registered peer before a
   `--port-forward` session from it will be accepted** — `controller_policy_rejection`
   in `nemo_management.rs` looks the controller up by id in the peer table, and a
   one-shot `--port-forward` CLI invocation never calls `RegisterPeer` itself. Run the
   controller's plain GUI client ONCE first (so it registers), THEN run
   `--port-forward` from the SAME `$HOME` (it reuses the same persisted id/device key).
7. **A freshly-registered peer defaults to blocked** (`status=0`). Call
   `POST /nemo/api/peers/<id>/allow` for BOTH the controller and the controlled id
   before the port-forward CLI will be let through — otherwise you get "controller is
   blocked by TBF policy".
8. The `--port-forward` CLI format is `<remote-id>:<local-port>:<remote-port>[:<remote-host>]`
   as ONE colon-joined string, and the password is read from **stdin**, not a flag:
   `./target/release/rustdesk --port-forward '<id>:<local>:<remote>:<host>' <<< '<otp>'`.
   Its own log is NOT on stdout — it is a GUI/session process; read
   `~/.local/share/logs/RustDesk/port-forward/rustdesk_rCURRENT.log` in that `$HOME`.
   This opens a small GTK/session window with an empty Local-port/Remote-PC/Remote-port
   table (the window title is literally the whole colon-joined string) — you still have
   to fill the three fields and click "Hinzufügen" (or the localised equivalent) once;
   the CLI only opens the window and authenticates, it does not add the row for you.
9. Send a test payload through the tunnel with plain bash, no extra tools needed:
   `exec 3<>/dev/tcp/127.0.0.1/<local-port>; printf 'MARKER' >&3; timeout 4 cat <&3`.
10. UNVERIFIED / left unresolved on 2026-09-28: after several `hbbs` restarts in the
    same lab session, a punch/relay request to an id that the admin API and the peer
    database both reported `online: true` still failed with `PunchHole Failure:
    ID_NOT_EXIST`. It looked like hbbs's in-memory peer/connection map disagreeing with
    the persisted `db_v2.sqlite3` state after a restart, not a fault in the port-forward
    code itself (the rendezvous handshake and OTP-based login worked correctly and
    repeatedly right up to that point in every attempt). Do not spend more than one
    retry on it: kill hbbs AND hbbr, delete the lab's `db_v2.sqlite3`, and start a fully
    fresh pair rather than restarting hbbs alone mid-session.

---

## 6. The Windows VMs

### 6.1 What exists

| Variant | Disk | OS | State file |
|---|---|---|---|
| `win11` (default) | `/projects/rustdesk/vm/disks/win11.qcow2` | Windows 11 Enterprise Eval (build 22000), hostname `TBFDESK-W11`, MAC `52:54:00:be:ef:11` | `/projects/rustdesk/vm/run/win11-mon.sock`, `/projects/rustdesk/vm/logs/win11-serial.log` |
| `win10` | `/projects/rustdesk/vm/disks/win10.qcow2` | Windows 10 Enterprise LTSC 2021, MAC `52:54:00:be:ef:10` | `/projects/rustdesk/vm/run/win10-mon.sock`, `/projects/rustdesk/vm/logs/win10-serial.log` |

Login: user `tbf` (autologon). SSH uses the key `/projects/rustdesk/vm/run/vmkey`; the scripts pass it for you.
Every `vmctl.sh` command targets `win11`. For win10, put `VM_VARIANT=win10` in front of the command.
The guest clock must be correct in UTC. A skewed clock makes the client fail with `HTTP 403 (sealed credential expired)`.

### 6.2 Status, start, stop

Step 6.2.1. Always first.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh status
```
Expect when running (numbers will differ; read them from YOUR output):
```
variant=win11
state=running
pid=<qemu pid>
ssh=tbf@127.0.0.1:<ssh port>
rdp=127.0.0.1:<rdp port>
vnc=:<n> (tcp <port>)
monitor=/projects/rustdesk/vm/run/win11-mon.sock
serial=/projects/rustdesk/vm/logs/win11-serial.log
disk=/projects/rustdesk/vm/disks/win11.qcow2
ssh=ready
```
Expect when stopped: `state=stopped` and no `pid=` line.
The SSH port is the number after the last `:` in the `ssh=tbf@127.0.0.1:` line. You do not need to type it: every `vmctl.sh` subcommand finds it by itself.
The final line is `ssh=ready` or `ssh=not-ready`. `status` hides SSH errors. To see the real error, run step 6.3.1.

Step 6.2.2. Start (only if `state=stopped` and the task needs the VM).
```sh
taskset -c 0-3,6,7,10,11,14-31 /projects/rustdesk/vm/scripts/vmctl.sh start win11
```
Expect: `starting win11 (launcher pid <n>, log /projects/rustdesk/vm/logs/win11-run-current.log)` or `win11 already running (pid <n>)`.

Step 6.2.3. Wait until SSH is ready (up to 5 minutes).
```sh
for i in $(seq 1 30); do /projects/rustdesk/vm/scripts/vmctl.sh status | grep -qx 'ssh=ready' && break; sleep 10; done; /projects/rustdesk/vm/scripts/vmctl.sh status
```
Expect: the last line is `ssh=ready`. If it is still `ssh=not-ready`, go to section 9.

Step 6.2.4. Check that QEMU avoids the faulty CPUs. Replace `<qemu pid>` with the `pid=` value from status.
```sh
taskset -cp <qemu pid>
```
Expect: the list `0-3,6,7,10,11,14-31`. If it contains 4,5,8,9,12 or 13, tell the human.

Step 6.2.5. Stop (graceful ACPI shutdown; only when the task needs it).
```sh
/projects/rustdesk/vm/scripts/vmctl.sh stop
```
Then run `vmctl.sh status` until it shows `state=stopped`.

Never start a second QEMU on the same disk. `run-vm.sh` refuses (`ERROR: VM pid N already running on ...`). Never open a live qcow2 with `qemu-nbd`, guestfish or another QEMU.

### 6.3 Run commands in the guest

Choose the cheapest path: PowerShell/SSH for files, processes, services, registry, installs, builds and logs. Never use screenshots for these.

Step 6.3.1. CMD command over SSH.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ssh 'whoami & hostname'
```
Expect: `tbfdesk-w11\tbf` and `TBFDESK-W11` (UNVERIFIED exact case).

Step 6.3.2. PowerShell one-liner.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps 'Get-Process rustdesk -ErrorAction SilentlyContinue | Select-Object Id,SessionId,Path'
```

Step 6.3.3. PowerShell script (no quoting problems). Type it exactly like this:
```sh
cat <<'PS' | /projects/rustdesk/vm/scripts/vmctl.sh ps
$ErrorActionPreference = 'Stop'
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion
Get-Process rustdesk -ErrorAction SilentlyContinue
PS
```
Do not call bare `powershell` over SSH; it is not on the SSH PATH. `vmctl.sh ps` uses the full path.

### 6.4 Copy files

Use Windows paths with forward slashes.
- Upload a file: `/projects/rustdesk/vm/scripts/vmctl.sh put <local file> 'C:/tbf-new/<name>'`
- Upload a folder: `/projects/rustdesk/vm/scripts/vmctl.sh put-dir <local dir> 'C:/tbf-new/<dir>'`
- Download a file: `/projects/rustdesk/vm/scripts/vmctl.sh get 'C:/tbf-new/<name>' <local file>`
- Download a folder: `/projects/rustdesk/vm/scripts/vmctl.sh get-dir 'C:/tbf-new/<dir>' <local dir>`
Success is exit code 0 and no output. Check with `echo "exit=$?"`.

### 6.5 Install and start the client in the guest

This fork has no installer in use. The client is "installed" by copying files to `C:\tbf-new\`: `rustdesk.exe`, `sciter.dll` (and `dylib_virtual_display.dll`, which is already there). The full steps are in section 8 (steps 8.3–8.9).
Do not run `--silent-install`, `--install-service`, `--install-idd` or `--install-remote-printer` in the guest without the human's ok: they install services and drivers.

### 6.6 Read config and logs in the guest

Step 6.6.1. Read the client config.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ssh 'type "C:\Users\tbf\AppData\Roaming\RustDesk\config\RustDesk2.toml"'
```
Short version with only the QA keys: `/projects/rustdesk/vm/scripts/cfgkeys.sh`

Step 6.6.2. Find the client log files.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps 'Get-ChildItem $env:APPDATA\RustDesk -Recurse -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object LastWriteTime,Length,FullName | Format-Table -AutoSize | Out-String -Width 300'
```
UNVERIFIED: the log folder. Upstream RustDesk writes logs under `%APPDATA%\RustDesk\log\`. This command searches the whole `RustDesk` folder, so it finds them either way.

Step 6.6.3. Read the newest lines of one log. Replace `<FullName>` with a path from 6.6.2.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps 'Get-Content -Tail 50 "<FullName>"'
```

Step 6.6.4. Host-side serial log and QEMU monitor.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh serial 100
```
```sh
/projects/rustdesk/vm/scripts/vmctl.sh monitor 'info status'
```
Expect for the monitor: `VM status: running`.

Step 6.6.5. Check the guest clock against the host.
```sh
date -u +%FT%T
```
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps '[DateTime]::UtcNow.ToString("s")'
```
Expect: the two times differ by less than a minute.

---

## 7. GUI control

### 7.1 When to use it

Use GUI control ONLY when the result you need is visual or interactive (a window appears, a button works, a dialog looks right).
Do NOT use screenshots to check files, processes, services, logs or config. Use `vmctl.sh ps` / `ssh` for those.
Pattern: one screenshot before, the smallest interaction, one screenshot after.

### 7.2 Windows VM tools

| Task | Command | Expect |
|---|---|---|
| Launch a GUI program so it is visible | `/projects/rustdesk/vm/scripts/vmctl.sh gui 'C:\tbf-new\rustdesk.exe'` (optional 2nd argument: one string of program arguments) | `launched: C:\tbf-new\rustdesk.exe` |
| Screenshot | `/projects/rustdesk/vm/scripts/vmctl.sh shot /projects/rustdesk/vm/shots/<name>.png` | `saved <file> (<W>x<H>)` |
| Click (in-guest agent) | `/projects/rustdesk/vm/scripts/vmctl.sh input CLICK <x> <y>` | the agent's reply |
| Double-click | `/projects/rustdesk/vm/scripts/vmctl.sh input DCLICK <x> <y>` | reply |
| Move mouse | `/projects/rustdesk/vm/scripts/vmctl.sh input MOVE <x> <y>` | reply |
| Type text | `/projects/rustdesk/vm/scripts/vmctl.sh input 'TYPE <text>'` | reply |
| Bring window to front | `/projects/rustdesk/vm/scripts/vmctl.sh input FOCUS RustDesk` | reply |
| List windows | `/projects/rustdesk/vm/scripts/vmctl.sh input WINS` | window list |
| Cursor position | `/projects/rustdesk/vm/scripts/vmctl.sh input CURSOR` | `x,y`-style reply |

Rules for the Windows VM:
- `vmctl.sh gui` starts the program in the interactive console session (session 1) with a one-shot scheduled task. A program started directly over SSH runs in session 0 and is invisible.
- Do NOT use `vmctl.sh click <x> <y>`. It sends QEMU tablet events, and in this guest they do not move the cursor (verified: the cursor stayed at 1279,799). Use `vmctl.sh input CLICK <x> <y>`.
- `input` needs the in-guest input agent `inputagent.ps1` running in session 1. It reads `C:\tbf-new\in.cmd` and writes `C:\tbf-new\in.done`. If `input` prints `(no reply)`, the agent is not running.
- UNVERIFIED: how to start the agent. Probably: first check it exists with `/projects/rustdesk/vm/scripts/vmctl.sh ssh 'dir C:\tbf-new\inputagent.ps1'`, then `/projects/rustdesk/vm/scripts/vmctl.sh gui 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\tbf-new\inputagent.ps1'`. If the file does not exist, stop and ask the human.
- `TYPE` uses Windows `SendKeys`. Wrap each of these characters in braces or the text is corrupted: `+ ^ % ~ ( ) { } [ ]`. Example: to type `a+b`, send `TYPE a{+}b`. Enter is `{ENTER}`, Tab is `{TAB}`.
- `FOCUS` finds the window from the process list. (`FindWindow` misses the Sciter window.)
- UNVERIFIED: that `CLICK` coordinates equal screenshot pixel coordinates. Check once with `input CURSOR` after an `input MOVE`.
- There is no OCR click script for the VM. Use the manual OCR steps in section 8 (8.12–8.15).
- The QEMU monitor can also press keys: `/projects/rustdesk/vm/scripts/vmctl.sh monitor 'sendkey ret'` (hardware level, works even without the agent).

### 7.3 Linux lab client tools (Xvfb display `:99`, window title exactly `TBFDesk`)

| Task | Command |
|---|---|
| Screenshot (from the root window, correct for tooltips/menus) | `/projects/rustdesk/vm/scripts/labshot.sh <out.png>` |
| Screenshot of the window surface only | `/projects/rustdesk/vm/scripts/labshot.sh <out.png> --win` |
| List all text on screen with coordinates (OCR) | `/projects/rustdesk/vm/scripts/labtap.py dump` |
| Find a label by OCR | `/projects/rustdesk/vm/scripts/labtap.py find "<label>"` |
| Click a label by OCR | `/projects/rustdesk/vm/scripts/labtap.py click "<label>"` (add `--cb` to click the checkbox 22 px left of the label) |
| Click a label and show the config change | `/projects/rustdesk/vm/scripts/labtoggle2.sh "<label>"` |
| Click window-relative pixels | `/projects/rustdesk/vm/scripts/labclick.sh <x> <y>` |
| Clear the focused field and type | `/projects/rustdesk/vm/scripts/labtype.sh "<text>"` |
| Press a key | `/projects/rustdesk/vm/scripts/labkey.sh <xdotool key name>` (e.g. `Return`) |
| Scroll | `/projects/rustdesk/vm/scripts/labscroll.sh down 5` |

Notes:
- `labtap.py` prints `FOUND '<text>' at win(x,y) -> click(x,y)` or `clicked '<text>' [--row] at win(x,y)`. On a miss it retries 3 times and then prints `NOT FOUND: '<label>' (after 3 retries)` and exits with code 2.
- OCR uses `tesseract` with `deu+eng` and `/projects/rustdesk/vm/tessdata`. Labels are German by default (e.g. `Verbinden`, `Einstellungen`).
- Use labels, not saved pixel coordinates: the settings dialog reflows on every re-render.
- `labcfg.sh`, `labtoggle2.sh` and `snap.sh` read the `arch-home` config only.
- Black rectangles in a `--win` capture are a capture artifact (tooltips/menus are separate X windows), not a bug.
- The client rewrites `RustDesk2.toml` in random key order. Always `sort` before you diff.

Container peers (`nemo-peer2` … `nemo-peer7`): `/projects/rustdesk/vm/scripts/peershot.sh <container> <out.png>` and `/projects/rustdesk/vm/scripts/peerclick.sh <container> click <x> <y>` | `type "<text>"` | `key <name>`.

---

## 8. Worked example: VM, copy client, launch, screenshot, click by label

Goal: start the Win11 VM, copy the Windows client in, launch it on the desktop, take a screenshot, click a button found by its label.

Step 8.1. Check the VM.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh status
```
If `state=stopped`: do steps 6.2.2 and 6.2.3. If `state=running` and `ssh=ready`: go on. If `ssh=not-ready`: see section 9.

Step 8.2. Make sure the guest folder exists.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ssh 'if not exist C:\tbf-new mkdir C:\tbf-new'
```
Expect: no output.

Step 8.3. Stop a running client (a running exe cannot be overwritten).
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ssh 'taskkill /IM rustdesk.exe /F'
```
Expect: `SUCCESS: The process "rustdesk.exe" with PID ... has been terminated.` OR `ERROR: The process "rustdesk.exe" not found.` Both are fine.

Step 8.4. Upload the client. (To use a build from section 4 instead, run `/projects/rustdesk/vm/scripts/vmctl.sh ssh 'copy /Y C:\build\rustdesk-client-nemo\target\release\rustdesk.exe C:\tbf-new\rustdesk.exe'` and skip to 8.6.)
```sh
/projects/rustdesk/vm/scripts/vmctl.sh put /projects/rustdesk/vm/artifacts/tbfdesk-windows-x64.exe 'C:/tbf-new/rustdesk.exe'; echo "exit=$?"
```
Expect: `exit=0`

Step 8.5. Upload sciter.dll.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh put /projects/rustdesk/rustdesk-nemo-flavour/downloads/sciter-x64/sciter.dll 'C:/tbf-new/sciter.dll'; echo "exit=$?"
```
Expect: `exit=0`

Step 8.6. Hash on the host.
```sh
sha256sum /projects/rustdesk/vm/artifacts/tbfdesk-windows-x64.exe
```
Step 8.7. Hash in the guest.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps '(Get-FileHash C:\tbf-new\rustdesk.exe -Algorithm SHA256).Hash'
```
Expect: the same hex string as 8.6 (the guest prints upper case; compare ignoring case).

Step 8.8. Launch the client on the visible desktop.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh gui 'C:\tbf-new\rustdesk.exe'
```
Expect: `launched: C:\tbf-new\rustdesk.exe`

Step 8.9. Check that it runs in the interactive session.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh ps 'Get-Process rustdesk | Select-Object Id,SessionId,MainWindowTitle | Format-Table -AutoSize'
```
Expect: at least one row with `SessionId` 1 (not 0). UNVERIFIED: the title contains `TBFDesk`.

Step 8.10. Wait 5 seconds, then take the "before" screenshot.
```sh
sleep 5; /projects/rustdesk/vm/scripts/vmctl.sh shot /projects/rustdesk/vm/shots/llm-example-before.png
```
Expect: `saved /projects/rustdesk/vm/shots/llm-example-before.png (<W>x<H>)`. Write down W and H.

Step 8.11. Look at the screenshot if you can read images. If not, use OCR (8.12–8.13).
What you should see (from the 2026-09-20 test): without a device key, the whole window shows "Dieses Gerät ist noch nicht eingerichtet" and one button **Geräteschlüssel importieren**. With a device key, the normal window shows the ID, a one-time password and the status **Bereit**.

Step 8.12. Enlarge the screenshot 2x (OCR reads small UI text better).
```sh
magick /projects/rustdesk/vm/shots/llm-example-before.png -resize 200% /tmp/llm-ocr-2x.png
```
Expect: no output.

Step 8.13. Run OCR and write a TSV file (`/tmp/llm-ocr.tsv`).
```sh
TESSDATA_PREFIX=/projects/rustdesk/vm/tessdata tesseract /tmp/llm-ocr-2x.png /tmp/llm-ocr -l deu+eng --psm 6 tsv
```
Expect: no error. The file `/tmp/llm-ocr.tsv` exists.

Step 8.14. List every word with its centre in screenshot pixels.
```sh
awk -F'\t' 'NR>1 && $12!="" && $11>=35 {printf "%d %d %s\n", ($7+$9/2)/2, ($8+$10/2)/2, $12}' /tmp/llm-ocr.tsv
```
Expect: lines like `640 412 Geräteschlüssel`. The first two numbers are x and y in the original screenshot.

Step 8.15. Get the centre of ONE word of the button label. Pick the most unusual word of the label (here `importieren`; for the normal window use `Verbinden`).
```sh
awk -F'\t' -v w='importieren' 'NR>1 && $12==w && $11>=35 {printf "%d %d\n", ($7+$9/2)/2, ($8+$10/2)/2; exit}' /tmp/llm-ocr.tsv
```
Expect: two numbers, `X Y`. If there is no output, the word was not read. Look at the list from 8.14 for the closest spelling, and use that exact spelling. If it is not in the list at all, the button is not on screen; stop.

Step 8.16. Check the input agent.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh input WINS
```
Expect: a list of windows. If it prints `(no reply)`, the agent is not running; see 7.2.

Step 8.17. Click the label. Replace X and Y with the numbers from 8.15.
```sh
/projects/rustdesk/vm/scripts/vmctl.sh input CLICK X Y
```
Expect: a reply from the agent (not `(no reply)`).

Step 8.18. Take the "after" screenshot.
```sh
sleep 2; /projects/rustdesk/vm/scripts/vmctl.sh shot /projects/rustdesk/vm/shots/llm-example-after.png
```
Step 8.19. Verify the result from the "after" screenshot (look at it, or repeat 8.12–8.14 on it). For the import button, the expected result is a dialog titled **Geräteschlüssel importieren** with a key field and the buttons **Abbrechen** and **OK**.
Report the two screenshot paths and what changed. Do not report success without the "after" evidence.

Step 8.20 (optional). To type into the dialog, click the key field (find it the same way), then:
```sh
/projects/rustdesk/vm/scripts/vmctl.sh input 'TYPE <text with + ^ % ~ ( ) { } [ ] wrapped in braces>'
```
Device keys are base64 and contain `+`. Every `+` must be sent as `{+}`.

---

## 9. Troubleshooting

| Symptom (exact text where known) | Cause | Fix |
|---|---|---|
| Machine freezes, or `rustc`/build scripts crash at random | Work ran on faulty CPUs 4,5,8,9,12,13 | Always prefix `taskset -c 0-3,6,7,10,11,14-31`. Check `cat /sys/devices/system/cpu/offline`. |
| `signal: 11` / `SIGSEGV` from `rustc` or from bindgen build scripts (hwcodec, v4l2-sys, pam-sys) | Too many parallel jobs | Use `-j 12`; if it happens again, `-j 8`. Not a code problem. |
| `Blocking waiting for file lock on build directory` | Another cargo is using the same `target/` | Wait. Do not kill it. Check with `pgrep -x cargo`. |
| `error[E0560]: struct aom_codec_dec_cfg has no field named threads` | bindgen older than 0.72.1 with LLVM 22 | Run `cargo tree -i bindgen` in the client repo; it must show 0.72.1 or newer. Do not edit headers. |
| `internal compiler error: in c_addr_space_name, at c-family/c-common.cc:657` (libgit2-sys) | GCC 16 bug | Build the client with `scripts/build-arch-client.sh` (sets `CC=clang`). |
| libsodium-sys / zstd-sys / openssl-sys build script fails | Vendored C sources do not build with GCC 16 | Client: `CC=clang CXX=clang++ SODIUM_LIB_DIR=/usr/lib SODIUM_SHARED=1 OPENSSL_NO_VENDOR=1` (the build script sets these). Server: `SODIUM_LIB_DIR=/usr/lib SODIUM_SHARED=1 ZSTD_SYS_USE_PKG_CONFIG=1`. |
| `ERROR: hwcodec needs a vcpkg tree with static ffmpeg but VCPKG_ROOT is unset` | No vcpkg found | `VCPKG_ROOT=/home/nemo/.cache/yay/rustdesk/src/vcpkg-120deac3062162151622ca4860575a33844ba10b` in front of the command. Do not use `NO_HWCODEC=1` for a build that ships. |
| `Missing packages: ...` | Arch packages not installed | Ask the human to run the printed `sudo pacman -S --needed ...`. |
| Client has no H.264/H.265 | Built without `hwcodec` | Rebuild with `--features linux-pkg-config,hwcodec` (Linux) or `inline,hwcodec,vram` (Windows). |
| Linux client panics at start in rust-sciter window flags | Debug build | Use the release build. |
| Linux client shows a blank/old UI | Started from the wrong folder | Start from the client repo root (`run-lab-client.sh` does). |
| `libsodium.so.26: not found` in a peer container | Client links libsodium dynamically | Install `libsodium` in that container. |
| Black rectangles in a screenshot | Window-only capture of Sciter tooltips/menus | Capture from root (`labshot.sh` without `--win`). |
| `labtap.py`: `NOT FOUND: '<label>' (after 3 retries)` | OCR miss or label not on screen | Run `labtap.py dump`, use the text exactly as OCR read it, or use fewer words. |
| `vmctl.sh status` ends with `ssh=not-ready` | VM still booting, or sshd not running | Run step 6.2.3 once. Then run `/projects/rustdesk/vm/scripts/vmctl.sh ssh 'echo ok'` to see the real error, and `/projects/rustdesk/vm/scripts/vmctl.sh serial 50`. Report both. Do not loop. |
| `Connection refused` / `Connection timed out` on ssh | Wrong port or VM not up | Run `vmctl.sh status` once and use what it reports. Never type a port. |
| `ERROR: VM pid N already running on ... refusing to start a second one.` | VM already running | Do not start it. Use `vmctl.sh status`. |
| `'powershell' is not recognized` | Bare `powershell` over SSH | Use `vmctl.sh ps`. |
| Program launched in the guest but no window on screenshots | Started over SSH (session 0) | Launch with `vmctl.sh gui`. Check `SessionId` is 1 (step 8.9). |
| `vmctl.sh click` does nothing | QEMU tablet events do not reach this guest's cursor | Use `vmctl.sh input CLICK x y`. |
| `input` prints `(no reply)` | In-guest input agent not running | See 7.2. |
| Typed text is wrong | SendKeys special characters | Wrap `+ ^ % ~ ( ) { } [ ]` in braces. |
| `HTTP 403 (sealed credential expired)` in the client log | Guest clock wrong | Compare clocks (6.6.5). UNVERIFIED fix (from CHECKLIST, needs admin): set the guest time zone to UTC and set the time to host UTC, e.g. `Set-TimeZone -Id UTC` then `Set-Date`. Ask the human first. |
| Client log: `NO DEVICE KEY is provisioned on this machine` / HTTP 403 | No device key | Mint a key for the client id (5.1.12) and import it in the GUI. |
| GUI shows only "Dieses Gerät ist noch nicht eingerichtet" | No device key (Layer 1 gate) | Same as above. This is correct behaviour. |
| Windows client shows "newer version of RustDesk available" | You are running the old master-era build from `downloads/nemo-rustdesk-windows-client-controller-policy.zip` | Use a current build (section 4 or `vm/artifacts/`). |
| Windows build: `CMAKE_MT-NOTFOUND`, RC "no such file" | Windows SDK missing, or not inside vcvars | Install SDK with `winsdksetup.exe /features +`; run vcpkg and cargo after `call vcvars64.bat`. |
| Windows build: `error[E0583]` for `mod inline` | `src/ui/inline.rs` missing | Do 4.4 and 4.5 again. |
| Windows link errors `libmfx.lib`, `swr_*`, `IID_ICodecAPI`, `IID_IMFTransform` | hwcodec link gaps | vcpkg port `mfx-dispatch`; check `build.rs` `build_windows()` still links swresample/swscale/mfuuid/strmiids/mfplat. |
| Windows client shows "Build unknown" | Built from a tarball without `.git` | Expected. |
| hbbs: `Refusing to serve the Nemo management API over plaintext HTTP on <addr>` | Routable bind without TLS | Bind `127.0.0.1:21120`, or add `--nemo-api-tls auto`, or (lab only) `--nemo-api-allow-insecure Y`. |
| hbbs: `Refusing to bind Nemo management API to <addr> without --nemo-api-token` | No token | Add `--nemo-api-token <t>` (production: `NEMO_API_TOKEN` in the env file). |
| hbbs: `--key-exchange=require needs a server signing key` | No key | Add `-k _` so hbbs uses `id_ed25519` in its folder. |
| `Fatal error: no id_ed25519 in ...` | Key file missing | Production: restore the backed-up key. Fresh lab only: add `--generate-key Y` to hbbs, start hbbs first, then hbbr in the same folder. |
| hbbs: `Fatal error: malformed private key in id_ed25519.` | Bad key file | Use an empty folder, or the correct key file. Do not delete a real server key. |
| `error binding to 127.0.0.1:21120 ... Address already in use (os error 98)` | Port taken | `ss -ltnp | grep 21120`; use the other server or stop yours by PID. |
| Relay never pairs, hbbr logs nothing | Relay address is loopback | Use the routable host address (5.1.3). From the VM this also applies. |
| A client never comes online; hbbs logs a warning naming it | Client uses UDP registration (`disable-udp=N`); server default `--udp-registration=N` | Set client `disable-udp=Y` (the default). |
| After a rebuild the "new" server fails to bind but an old one answers | Old process still running; `/proc/<pid>/exe` reads `<path> (deleted)` | Find it: `for p in /proc/[0-9]*; do e=$(readlink $p/exe 2>/dev/null); case "$e" in *hbbs*) echo "${p#/proc/} $e";; esac; done` and `kill <pid>`. |
| Your shell died while stopping something | You used `pkill -f` | Never use it. Use PIDs. |
| `git status` shows ` M db_v2.sqlite3` in the server repo | Runtime DB, changed by runs | Normal. Never add or commit it. Never `git checkout` it. |

---

## 10. List of UNVERIFIED items

1. Whether `message.proto` must be identical between client and server. On 2026-09-27 it differs; `rendezvous.proto` is identical.
2. The guest folder of the client source for Windows builds (`C:\build\rustdesk-client-nemo` is assumed).
3. The exact guest paths of `vcvars64.bat`, LLVM (`LIBCLANG_PATH`) and vcpkg (steps 4.2–4.3 find them).
4. That `cargo.exe` is at `%USERPROFILE%\.cargo\bin\cargo.exe` in the guest.
5. The Rust version needed for the Windows Sciter build (README says 1.75).
6. How to start the in-guest input agent `inputagent.ps1`, and whether it is still in `C:\tbf-new\`.
7. That `input CLICK` coordinates equal screenshot pixels (true only at 100% display scaling).
8. The guest client log folder (upstream default `%APPDATA%\RustDesk\log\`).
9. The window title of the Windows client (expected to contain `TBFDesk`).
10. The exact case of `whoami`/`hostname` output in the guest.
11. The guest clock fix commands.
12. The client config for the native loopback lab (adapted from other scripts).
13. The Brave/Chromium launch command for `cdp.mjs`.

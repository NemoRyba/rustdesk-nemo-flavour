# TBFDesk — Lab handoff: Flutter port (Windows, Linux, Android) + Sciter fixes

**Date: 2026-11-02. For: the lab machine that builds and tests (video tests run there).**
Nothing in this handoff has been built or run yet — every commit below was checked for syntax
only (`dart format -o none`, `rustfmt --check`). Expect compile errors on the first build;
fixing them is step 1 of the lab work.

Read with: [FLUTTER-PORT.md](FLUTTER-PORT.md) (what was ported, progress table, open
follow-ups, operator decisions §10), [LAB-VIDEO-TEST-PLAN.md](LAB-VIDEO-TEST-PLAN.md) (what to
record), [OPEN-TODOS.md](OPEN-TODOS.md) #49-#54.

---

## 1. What to check out

| Repo | Branch | Head (2026-11-02) | Note |
|---|---|---|---|
| client `rustdesk-client-nemo` | **`nemo-tdd-flutter`** | `28ffdb6dc` | `nemo-tdd` + 28 commits. Contains BOTH the Flutter port and Sciter fixes. |
| hbb_common (submodule `libs/hbb_common`) | **`nemo-quality-min1`** | `fe74601` | gitlink in the client points here; = `nemo` + custom quality min 1 %. **Merge into `nemo` after the lab confirms** (operator approval pending). |
| superproject `rustdesk-nemo-flavour` | `ccr-946cdbb1-g5j1sj` | — | docs only (this file, FLUTTER-PORT, LAB-VIDEO-TEST-PLAN, OPEN-TODOS). |
| server `rustdesk-server-nemo` | `nemo-tdd` | unchanged | lab hbbs/hbbr as today (`vm/lab2`). |

```bash
cd rustdesk-client-nemo
git fetch origin nemo-tdd-flutter && git checkout nemo-tdd-flutter
git submodule update --init libs/hbb_common   # fetches fe74601 from NemoRyba/hbb_common
git -C libs/hbb_common log --oneline -1       # must say: config: custom image quality minimum 1 %
```

Side branches already merged into `nemo-tdd-flutter` (no need to test separately):
`nemo-tdd-remote-cursor-shape` (Sciter cursor fix, #49) and `nemo-tdd-open-recording-folder`
(Open buttons, ProgramData default + network-last ordering).

## 2. Toolchain (pin to what CI uses)

| Tool | Version | Source |
|---|---|---|
| Flutter | **3.24.5** (desktop and Android) | `.github/workflows/flutter-build.yml` |
| flutter_rust_bridge_codegen | **1.80.1** (`cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked`) | `bridge.yml` |
| Rust | 1.75 for Sciter builds (ABI); Flutter builds as CI | `flutter-build.yml` |
| vcpkg | commit `120deac3062162151622ca4860575a33844ba10b` (ffmpeg for hwcodec) | `flutter-build.yml` |
| cargo-ndk | 3.1.2; Android NDK as upstream CI; **Android SDK platform 37** (Android 17) | `flutter-build.yml`, decision §10.10 |

## 3. Build recipes

### 3.0 Generate the Rust↔Dart bridge (REQUIRED before any Flutter build)
The bridge is generated, not committed. ~30 new `main_nemo_*` functions and
`session_capture_displays` were added in `src/flutter_ffi.rs`.
```bash
~/.cargo/bin/flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart
cd flutter && flutter pub get   # share_plus ^10.1.2 is new
```
Then `flutter analyze` once and fix what it reports before building (see §5).

### 3.1 Windows (Flutter)
```bat
python build.py --flutter --hwcodec --vram
```
The installer/packaging path for the Flutter bundle (data/, flutter_windows.dll,
librustdesk.dll) is NOT adapted yet (FLUTTER-PORT §8 P6) — for the lab run the built
`flutter\build\windows\x64\runner\Release\` folder directly, or a portable build.

### 3.2 Linux (Flutter)
```bash
python3 build.py --flutter --hwcodec --unix-file-copy-paste
```

### 3.3 Sciter (the shipped build) from the same branch
As today (`build-run-windows-client.ps1`, `--features inline,hwcodec,vram`; Linux per
`tests/lib/client-env.sh`). Needed because the cursor fix, Open buttons, recording-folder
ordering, "(locked)" fix and quality floor also change the Sciter client.

### 3.4 Android (arm64, Pixel 7a on Android 17)
```bash
cd flutter && ./ndk_arm64.sh          # cargo ndk ... --features flutter,hwcodec
# copy target/aarch64-linux-android/release/liblibrustdesk.so -> android/app/src/main/jniLibs/arm64-v8a/librustdesk.so (as upstream CI)
flutter build apk --target-platform android-arm64 --debug     # lab: debug-signed is fine
```
- minSdk/targetSdk/compileSdk = **37** (`flutter/android/gradle.properties`). AGP 7.3.1 /
  Gradle 7.6.4 predate API 37 → if the build fails on the SDK level, upgrade AGP (8.x+) and
  the Gradle wrapper; record what was needed in FLUTTER-PORT.
- applicationId `at.tbf.tbfdesk` (same file). Release signing: `flutter/android/SIGNING.md`
  — NOT needed for the lab.
- iOS is shelved (§10.14) — do not build.

## 4. What changed and must be tested

### 4.1 Security fixes (P0) — test first, both by inspection and by behaviour
| # | Check | How |
|---|---|---|
| S1 | Flutter never hands `nemo-device-key` to Dart; a settings save keeps it and the policy state | Flutter devtools / debug print of `bind.mainGetOptions()` → no key. Save any setting → `TBFDesk2.toml` still has `nemo-device-key`, `nemo-blocked-ids`, `nemo-peer-keys` unchanged |
| S2 | Update prompt exists under Flutter | Lab update server offers a version → service spawns `--nemo-update-prompt` → window with countdown / Postpone / Now (V11) |
| S3 | Upstream unverified download path refused | Log line "download-new-version refused…"; no installer downloaded by the UI |
| S4 | Sign-in is sealed | hbbs log / capture: `/api/login` body has `sealed`, no plaintext password |
| S5 | All API calls via Rust HTTP client | Self-signed lab server with "allow insecure TLS" → sign-in, AB, groups all work; with the cert pin set, a different cert is refused |

### 4.2 Feature parity — record per LAB-VIDEO-TEST-PLAN
Record **V01-V15 + V10b** for the **Flutter Windows**, **Flutter Linux** and **Sciter
Windows** builds. Mapping of commits → videos is in FLUTTER-PORT "Progress". Priorities:
1. V01 gates + import, V02 sign-in + certificate box, V05 sealed address book.
2. V10 remote window + **V10b display modes / picker** (span: 2 remote displays on 2 local
   monitors; check the limits listed in FLUTTER-PORT "Span mode limits").
3. V06 settings incl. the **non-existent API / ID / relay server** demonstrations.
4. V09 recording folders (ProgramData default, roaming-profile UNC, network last).
5. V10 cursor-shape checklist (#49) on **Sciter** — the fix is Sciter-only (Flutter was correct).

### 4.3 Android (Pixel 7a, Android 17) — no video plan yet; use FLUTTER-PORT §9b A7
- Install (debug APK). App name **TBFDesk**, accessibility service **TBFDesk Input**.
- Standalone mode (no device key): connect to a lab Windows host; Direct/Relay chip; display
  number picker.
- Fleet mode: Settings → Import → QR scan of a lab setup string → summary → claim/sign-in
  gates as configured; sealed sign-in; address book.
- Controlled phone: share screen + accessibility input from a Windows controller; cut the
  session from the dashboard → session ends on the phone.
- Settings → Support → **Share log** → share sheet lists installed messengers/mail.
- `tbfdesk://` deep link opens the app.

## 5. Expected first-build problems (fix, then note in FLUTTER-PORT)
- **Bridge names/types**: Dart calls were written against the expected codegen names
  (`bind.mainNemoXxx(named: ...)`; `SyncReturn<T>` → plain `T`). A mismatch shows in
  `flutter analyze` — adjust the Dart call, not the Rust signature.
- **Agent-written Dart** (mobile pages, remote toolbar display modes, span mode in
  model.dart / input_model.dart / remote_page.dart): type errors and missing imports likely.
- `share_plus ^10.1.2` vs Flutter 3.24.5 / Dart SDK constraint — downgrade to the newest
  compatible version if `pub get` refuses.
- `file_picker ^5.1.0` `saveFile` (desktop certificate download) — desktop only.
- **Web bridge stubs** missing (`flutter/lib/web/bridge.dart`) — web is not a target; ignore.
- Android: API 37 vs AGP 7.3.1 (above); Kotlin APIs deprecated/removed at SDK 37.
- `ui.rs` / Sciter: new binding `nemo_exe_server_locked`; `index.tis` calls it — run the
  `sciter-parse` stage.

## 6. Existing automated stages to run
```bash
tests/run-all.sh --quick          # unit + contract + static (no display)
tests/run-all.sh                  # + Linux GUI (Sciter)
tests/run-all.sh --all            # + Windows VM stages
```
`unit-client` covers the moved helpers (ui_interface secret filter / managed-state tests moved
from ui.rs). The GUI stages drive the **Sciter** client; Flutter GUI automation is part of the
video-test TODO (#52).

## 7. Known limitations (documented, not bugs to chase)
FLUTTER-PORT "Open follow-ups" items 3, 5, 7, 8, 9 and the span-mode limits; Flutter's
"All" with a display subset keeps real positions (gap); Management/Import rows behind
"Unlock Network Settings" on installed Flutter clients; mobile session has no display-subset
picker (upstream single-display switching).

## 8. Report back
- Per video: PASS/FAIL (index page of the video run), failures as OPEN-TODOS entries with
  the video timestamp.
- Build fixes: commit on `nemo-tdd-flutter` with a message saying what the first build needed.
- Confirm or reject: merge of hbb_common `nemo-quality-min1` into `nemo`; Android toolchain
  upgrade if needed.
- Still pending from the operator: TBFDesk icon (1024² PNG) — Android still shows the
  RustDesk icon.

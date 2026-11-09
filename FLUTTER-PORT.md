# TBFDesk — Port from Sciter to Flutter (desktop + Android)

**Status: IN PROGRESS (2026-11-02) — desktop (Windows + Linux) first; Android documented only (§9b, OPEN-TODOS #51).**
Client branch: **`nemo-tdd-flutter`** (from `nemo-tdd` `fe95013cd`, with
`nemo-tdd-remote-cursor-shape` and `nemo-tdd-open-recording-folder` merged in: `9bb5ba2f6`).
Supersedes the planning notes in OPEN-TODOS #38 (mobile parity) and #39 (one UI everywhere).

Goal: one Flutter UI for Windows, Linux and Android that has **every** TBFDesk feature the
Sciter desktop UI has today, with no backend feature silently lost on the way.

Line numbers below refer to `nemo-tdd-flutter` at `9bb5ba2f6` unless a commit is named.
Fork point with upstream RustDesk: `b81ae6c8`.

---

## Progress (2026-11-02) — desktop port written, NOT yet built

Client branch `nemo-tdd-flutter`, commits after the merge `9bb5ba2f6`:

| Commit | Content | FLUTTER-PORT rows |
|---|---|---|
| `83073d0f4` | device key never handed to Dart; kept + managed state restored on save (shared ui_interface helpers) | §2.1 |
| `df335d525` | TBFDesk FFI layer (all `main_nemo_*`), helpers moved from ui.rs to ui_interface; update prompt window | §2.2, §4 |
| `eed67a463` | upstream unverified download/run refused; TBF update banner | §2.3, A16 |
| `b22a5b8d9` | gates (device key / claim / sign-in), import dialog, account bar, ⋮ menu, build id, policy checks, registration badge, direct hint, refusal translation, no install nag / pencil | A1-A3, A6, A7, A13-A15, A17, A19, A26 |
| `0c2e88573` | install page EULA without rustdesk.com | D1 |
| `cd9e125b7` | sealed AB (/api/ab/get, envelope, unseal, own id hidden), ab-version reload, AB sign-in tip, empty text, reload icon, search hint, Direct chip, peer menu (direct / relay / reset) | B1, B3-B8, A21 |
| `a1fbb7078` | sealed sign-in page + certificate box; login via sealed flow; logout clears user ticket | A4, A5, §2.4 |
| `55a99cf3d` | every API request through the Rust HTTP client (TLS fallback, cert pin, proxy) | — |
| `53fde4442` | settings parity: tooltips, fixed rows, Alias, Management, Import row, server dialog locks + company-only, language DE/AT/EN flags, clipboard-sync toggle, inert auto-update row, About TBFDesk, no privacy mode / login in settings | A8-A12, A18, A20, R8 (settings) |
| `dccc31db4` | remote window: display modes + picker + persistence, Direct/Relay badge, privacy hidden, quality min 1 %, tooltips, in-process clipboard sync, shrink view style | R1-R11, R14 |
| `12c246c49` | explicit adaptive default view style honoured; 1 % slider steps | R14, R9 |

| `5a35fba62` | custom quality 1-9 % saved (hbb_common `nemo-quality-min1` fe74601 — merge into `nemo`) and honoured by the host (video_qos floor) | R9, follow-up 1 |
| `a998aba68` | AB tags pane on the right | B2, follow-up 4 |
| `0c4f82ec7` | "(locked)" only while no setup string overrides the exe-name server (both UIs) | follow-up 6 |
| `f592940e6` | exact span: remote display i on local monitor i, per-tile pointer + cursor mapping | follow-up 2 |
| `bd08f329c` | mobile: management client + log collect on Android/iOS, optional fleet gate | §9b A1 |
| `527d1d62a` | Android/iOS packaging renamed (at.tbf.tbfdesk, labels, tbfdesk://, SIGNING.md) | §9b A6 |
| `af659907b` | mobile UI: fleet gate, QR/paste/file import, settings, share log, badges | §9b A2-A5 |
| `2f6ae1211` | key_confirmed in Flutter status (Registered badge), mobile cert/file handling, strings | A15 |

**Span mode limits to check in the lab (V10b):** Wayland (window cannot be positioned),
Linux GDK_SCALE ≠ 1, macOS Retina units, Windows invisible resize borders (few-px offset),
monitor hot-plug / user moving the window while spanning (layout recomputed only on enter or
subset change), relative mouse mode in span, OS-close while spanning saving "fullscreen".

**Mobile, still needed from the operator:** TBFDesk icon (1024² PNG). (Apple team id: future,
iOS shelved; Firebase plist removed; Android 17 = minimum — decided 2026-11-02.)

**Verification so far: syntax only** (`dart format -o none`, `rustfmt --check`). Not done:
flutter_rust_bridge codegen, `flutter analyze`, `cargo check --features flutter`, a Windows
and Linux build, the lab parity sweep (LAB-VIDEO-TEST-PLAN.md, OPEN-TODOS #52).

**Open follow-ups / deviations**
1. **(FIXED, see progress table)** hbb_common: custom image quality below 10 % is not persisted —
   `PeerConfig::deserialize_custom_image_quality` accepts only `v[0] >= 10` and
   `UserDefaultConfig` clamps `custom-image-quality` to ≥ 10.0. Lower both to 1 (affects Sciter
   too), bump the client gitlink.
2. **(FIXED, see progress table)** Span mode: window covers all monitors with the "all" layout; the exact "remote display i
   on local monitor i" mapping is TODO (needs per-display pointer mapping in InputModel).
3. "All" with a display subset keeps real positions (gap for an unpicked middle display);
   Sciter packs tiles side by side.
4. **(FIXED, see progress table)** AB tags pane stays left (Sciter: right) — operator decision.
5. Settings: Management + Import rows sit behind Flutter's "Unlock Network Settings" on an
   installed client; Direct IP access stays in the Security tab (next to the whitelist).
6. **(FIXED, see progress table)** Exe-name lock: Flutter treats a non-empty licence as locked; a setup string that overrides
   the exe-name server (`nemo_exe_custom_server_configured`) is not mirrored → "(locked)" may
   show although the import overrode it.
7. Web bridge (`flutter/lib/web/bridge.dart`) has no stubs for the new FFI — web is not a
   target; add stubs only if a web build is ever needed.
8. Direct/Relay badge on the mobile toolbar → Android (§9b).
9. Install nag removed for all Windows non-installed runs (portable use shows no prompt).

---

## 0. Summary

1. **Flutter is untouched upstream code.** Since `b81ae6c8` only two Dart files changed:
   `desktop_setting_page.dart` (Open-recording-folder button) and `tabbar_widget.dart`
   (TBFDesk label). `src/flutter.rs` and `src/flutter_ffi.rs` have **zero** diff.
2. **The backend is shared and mostly works under Flutter desktop already** (policy poll,
   control tickets, direct + knock, rendezvous hardening, audit, lock after session end,
   service auto-update, CLI `--import-setup`). What is missing on desktop is the **UI and its
   bindings**: ~31 `handler.nemo_*` functions in `src/ui.rs` have no FFI counterpart.
3. **Three backend problems surface only under Flutter and must be fixed before a Flutter
   build ships** (§2): the device key leaks through the option getters and can be wiped by a
   settings save; the update prompt does not exist; the stock Flutter manual update skips the
   SHA-256 check.
4. **Android gets almost none of the fork's policy-driven features today**: the management
   client is not compiled for Android, and Android has no way to import a setup string or
   device key. Without that, control tickets, direct endpoints, peer keys, required login,
   audit uploads and the address-book seal are inert on the phone (§3).
5. Sciter-only plumbing that has to be re-done in Dart/FFI, not just re-skinned: the display
   modes (all / span / one window per display + subset picker) and the sealed login + sealed
   address book flow.

---

## 1. How the two UIs reach Rust

| | Sciter (today) | Flutter (target) |
|---|---|---|
| Main window bindings | `src/ui.rs` `impl UI`, registered in the `sciter::dispatch_script_call!` list (`ui.rs` ~1468-1533) | `src/flutter_ffi.rs` `pub fn main_*` → flutter_rust_bridge → `bind.main*` in Dart |
| Session bindings | `src/ui/remote.rs` `SciterSession` | `src/flutter_ffi.rs` `session_*`, `src/flutter.rs` `FlutterHandler` (InvokeUiSession) |
| Startup | `core_main()` → `ui::start()` | desktop runners call `core_main()` (`flutter/windows/runner/main.cpp:31-53`, `flutter/linux/main.cc:27`); Android calls `Java_ffi_FFI_startServer` (`flutter_ffi.rs:3043-3061`), `core_main` never runs |
| Module gating | `src/lib.rs`: `ui` excluded when `feature="flutter"` (23-30) | `flutter`, `flutter_ffi` built for android/ios/flutter (33-38) |

Build features: `Cargo.toml` `default = ["use_dasp","nemo-management-client"]`; `build.py:274-288`
adds `flutter[,hwcodec,vram,unix-file-copy-paste]`; Android `flutter/ndk_*.sh` adds
`flutter[,hwcodec]`; CI `.github/workflows/flutter-build.yml`. Defaults stay on everywhere.

**Rule for the port:** every new FFI function is a thin wrapper over the same Rust function the
Sciter binding calls — no logic in `flutter_ffi.rs`, no logic duplicated in Dart that already
exists in Rust (`nemo_setup`, `nemo_direct`, `common::nemo_*`).

---

## 2. MUST-FIX before any Flutter build ships (security / correctness)

### 2.1 Device key exposed and clobbered through the Flutter option API
- Sciter hides the secret: `src/ui.rs` `NEMO_SCRIPT_SECRET_OPTIONS` filtered in `get_option` /
  `get_options`; on save `nemo_reinject_script_secrets` + `nemo_restore_managed_state` put back
  the hidden key and the server-managed state (`nemo-terminate-acked`, `nemo-policy-issued-ts`,
  `nemo-policy-seal-seen`, `nemo-blocked-ids`, `nemo-peer-keys`,
  `nemo-require-encrypted-session`).
- Flutter: `flutter_ffi.rs:954` `main_get_option`, `:1034` `main_get_options` return
  `nemo-device-key` in clear to Dart; `:1042` `main_set_options` does neither re-inject nor
  restore → a settings save from Flutter can **wipe the device key** or **roll back policy
  state** (replay guard, blocklist, peer keys).
- Fix: move the filter/re-inject/restore into `ui_interface` (shared) and call it from both
  `ui.rs` and `flutter_ffi.rs`. Add a test: get_options never contains the key; set_options
  with the key absent keeps it.

### 2.2 Update prompt does not exist under Flutter
- `updater.rs:385-435` spawns `--nemo-update-prompt` as the user; only Sciter handles it
  (`ui.rs:197-208` → `src/ui/update.html`). Under Flutter `core_main.rs:1122-1123` falls through
  to `flutter_args=[]`, `main.dart:111-118` opens a main window (or the single-instance check
  swallows it). No decision is ever written → the update installs after 65 s
  (`PROMPT_SECS`=60 + 5) with **no postpone and no visible prompt**.
- Fix: `core_main` branch returning flutter args for `--nemo-update-prompt`; Dart
  `main.dart` branch → small always-on-top window: title, text with version, countdown,
  Postpone (if allowed), Now; answer via FFI `main_nemo_update_answer`
  (`updater::OPTION_UPDATE_DECISION`), args via `main_nemo_update_prompt_args`.

### 2.3 Stock Flutter manual update bypasses the SHA-256 check
- `common.rs:1042-1050` hands Flutter `check_software_update_finish` the raw `manifest.url`,
  not the resolved `download` (`:1057-1060`). `flutter_ffi.rs:2910-2957`
  (`download-new-version` / `update-me`) downloads and runs `platform::update_to` **without
  verifying `NEMO_UPDATE_SHA256`** (Windows/macOS path).
- Fix: replace that path with the fork's IPC request (`ui.rs:786-794`,
  `updater::OPTION_UPDATE_REQUEST`, the service does the verified install), push the resolved
  download URL at `common.rs:1046`, and hide upstream's download link
  (`desktop_home_page.dart:440-466`).

### 2.4 Flutter login posts the password in clear
- `flutter/lib/models/user_model.dart:178-180` → plain `/api/login`. The fork's flow is sealed
  (§5 A4). Against a server that requires sealed/device-key login the per-user poll and the
  user control ticket fail. Port the sealed flow before shipping.

---

## 3. Backend activation: desktop Flutter vs Android

| Feature | Desktop Flutter today | Android today | To activate |
|---|---|---|---|
| Management poll (`nemo_management_client.rs`) | **Active** — `server.rs:628-629` runs in UI + `--server` processes (caveat 2.4) | **Not compiled** (`lib.rs:41-45` `not(android/ios)`); mobile `start_server` (`server.rs:599-603`) only starts rendezvous | `lib.rs:41-44` drop `not(android/ios)`; call `nemo_management_client::start()` in `server.rs:601-603` (Android) / `flutter_ffi.rs` `initialize()` (iOS, client-only); ungate `terminate_all_authed_sessions` call at `nemo_management_client.rs:255` (fn at `connection.rs:5864` is ungated). Already Android-safe: `set_permanent_password_with_result` (`ui_interface.rs:737-741`), `refresh_options` no-op, `nudge_updater` win/linux only (`:799`) |
| Setup string / device-key import (`nemo_setup.rs`, `common::nemo_device_*`) | CLI `--import-setup` **active** (`core_main.rs:739-790`, service push `1303,1358` → `ipc.rs:1798`); GUI dialog **missing** | Compiled, **unreachable** (no CLI, no FFI; `ui_interface.rs:496` android `nemo_set_provisioned_options` has no caller) → `nemo_device_sign` returns `("","")` | FFI + Dart dialog (§5 A3); on Android `apply_setup` in-process |
| Sealed login / sealed AB / sealed envelope (`common.rs:2686, 2937, 2980, 3012, 3050`) | **Inactive** (Dart uses plain requests) | **Inactive** | FFI + Dart login/AB rewrite (§5 A4, B8) |
| Control tickets (`nemo_control.rs`; controller `client.rs:3244`; target `connection.rs:2542` → `2337-2400`) | **Active** (depends on 2.4 for user ticket) | Compiled, **inert**: `required()` (`nemo_control.rs:250`), epoch, `nemo-management-public-key` only set by poll/setup; no ticket for outgoing | poll + import on Android |
| Lock after session end (`connection.rs:4800-4810`, `nemo-lock-after-session-end`) | **Active** | **Inactive** (`lock_screen` gated not(android/ios)) | Android: DevicePolicyManager via JNI + poll. Low priority |
| Direct + knock (`client.rs:427-681`, `nemo_direct.rs`) | Automatic path **active**; force-direct / endpoint label / knock hint UI **missing** | Compiled, **inert** (no endpoints without poll) | FFI + UI (§5 A14, B6, B7); poll on Android |
| Logs (`nemo_logs.rs`) | Compiled, **never invoked** (no FFI) | **Not compiled** (`lib.rs:57`) | FFI + ⋮ menu; Android: ungate + "share log" intent instead of open-folder (`nemo_logs.rs:142-147` has no android branch) |
| Updater (`updater.rs`) | Service auto-update **active** with SHA-256 (`updater.rs:247-260`); prompt **broken** (2.2); manual path **unsafe** (2.3) | **Not compiled** (`lib.rs:80`); `nemo_update_platform()` → None | §2.2/2.3. Android: store/MDM distribution, hide banner |
| Audit + direct-session reporting (`connection.rs:1114,1370,1393-1500`; `ui_session_interface.rs:2068-2092`; `nemo_direct.rs:351`) | **Active** (needs device key + api-server) | Runs, **uploads skipped** ("no device key", `connection.rs:1482`) | import on Android |
| Connection hardening (blocklist `connection.rs:1568`, encrypted session `server.rs:211-279`) | **Active** | **Active with defaults only** (`nemo_require_encrypted_session` defaults on; no `nemo-peer-keys` → direct-IP fails closed) | poll on Android |
| Rendezvous hardening (`rendezvous_mediator.rs`, `common.rs:2406-2433` fail-closed secure_tcp) | **Active** | **Active** | — |
| Pinned HTTP (`hbbs_http/http_client.rs`, `common.rs:1662 nemo_pin_for_url`) | **Active** | no consumer (no poll) | poll on Android |
| Outbound / company-network policy (`client.rs:205-224, 376, 482-487`) | **Active** (msgbox) | Active but options never set | poll on Android |
| Ctrl+Alt+Del / Ctrl+Alt+End → SAS (`keyboard.rs:950-952, 997-1035`) | **Active** | **Active** (hardware keyboard) | — |
| Default view style "shrink" until chosen per peer (`ui_session_interface.rs:238-254`, `client.rs:2452-2462`) | **Active** — verify Flutter's per-user default view style is not confusingly ignored | n/a | — |
| Clipboard sync between controller sessions (`clipboard.rs:17-42, 268, 409-419, 586-634`) | **Never fires**: Flutter desktop runs all sessions in one process, `CLIPBOARD_INSTANCE_ID` is the same for all | n/a | needs a new in-process mechanism (§6 R7) |
| Tray Exit + TBFDesk tooltip (`src/tray.rs`) | **Active** (Flutter uses the same `--tray` process) | n/a | — |
| German default language, AGPL attribution guard (`src/lang.rs`) | **Active** | **Active** | — |
| Locked/fixed option guards (`ui_interface` `nemo_preserve_locked_server_options`, `nemo_restore_fixed_options`, `set_option` refusal) | **Active** | **Active** | — |

---

## 4. FFI bindings to add (`src/flutter_ffi.rs`)

Mirror of the Sciter bindings in `src/ui.rs` (and `new_remote`/`open_folder`). Names are the
Dart-side `bind.main*` names after codegen.

| Sciter `handler.*` | New FFI | Rust implementation | Android |
|---|---|---|---|
| `get_build_id` | `main_get_build_id` (SyncReturn) | `ui_interface.rs:861` (`NEMO_BUILD_ID`) | yes |
| `nemo_device_key_present` | `main_nemo_device_key_present` | `common.rs:2774` | yes |
| `nemo_claim_status` | `main_nemo_claim_status` | `common.rs:2805` | yes (needs poll) |
| `nemo_device_key_candidate_valid` | `main_nemo_device_key_candidate_valid` | `common.rs:2847` | yes |
| `nemo_device_key_fingerprint` | `main_nemo_device_key_fingerprint` | `common.rs:2821` | yes |
| `nemo_is_setup_string` | `main_nemo_is_setup_string` | `nemo_setup.rs:106` | yes |
| `nemo_apply_setup_string` | `main_nemo_apply_setup_string` | `nemo_setup.rs:116` + `:240`, `ui_interface.rs:481/497` | yes |
| `nemo_setup_summary` | `main_nemo_setup_summary` | `NEMO_SETUP_SUMMARY` (move out of `ui.rs` into `nemo_setup`) | yes |
| `nemo_read_text_file` / `nemo_save_text_file` | not needed — use Dart `dart:io` + `file_picker` (limit 64 KB) | — | via SAF / share |
| `nemo_cert_info_start` / `_result` | `main_nemo_cert_info_start/_result` (or one async FFI) | `common.rs:1825/1833` | yes |
| `nemo_seal_login` | `main_nemo_seal_login` | `common.rs:2686` | yes |
| `nemo_open_login_reply` | `main_nemo_open_login_reply` | `common.rs:3050` | yes |
| `nemo_seal_envelope` | `main_nemo_seal_envelope` | `common.rs:2980` | yes |
| `nemo_sealed_request_enabled` | `main_nemo_sealed_request_enabled` | `common.rs:3012` | yes |
| `nemo_ab_seal_fields` | `main_nemo_ab_seal_fields` | `common.rs:2868` (`nemo_device_sign`) | yes |
| `nemo_unseal_ab` | `main_nemo_unseal_ab` | `common.rs:2937` (`nemo_open_sealed_signed`) | yes |
| `nemo_configured_api_server` | `main_nemo_configured_api_server` | `Config` (move from `ui.rs` to `ui_interface`) | yes |
| `nemo_direct_endpoint` | `main_nemo_direct_endpoint` | `nemo_direct.rs:220` | yes |
| `nemo_knock_hint` | `main_nemo_knock_hint` | `nemo_direct.rs:198, 205` | yes |
| `nemo_direct_ids` | `main_nemo_direct_ids` | `nemo_direct.rs:229` | yes |
| `nemo_force_direct` / `nemo_set_force_direct` | `main_nemo_force_direct` / `main_nemo_set_force_direct` | `nemo_direct.rs:172`, `PEER_OPTION_FORCE_DIRECT` | yes |
| `nemo_reset_peer_prefs` | `main_nemo_reset_peer_prefs` | `PeerConfig` (move from `ui.rs` to `ui_interface`) | yes |
| `nemo_open_log_folder` | `main_nemo_open_log_folder` | `nemo_logs.rs:140` | desktop |
| `nemo_copy_recent_log` | `main_nemo_collect_recent_log` (return text; Dart puts it on the clipboard) | `nemo_logs.rs:97` | Android after ungating |
| `nemo_update_state` | `main_nemo_update_state` | `updater.rs`, `common.rs:1084` | returns none |
| `nemo_update_now` | `main_nemo_update_now` | `updater::OPTION_UPDATE_REQUEST` via IPC | no |
| `nemo_update_prompt_args` / `nemo_update_answer` | `main_nemo_update_prompt_args` / `main_nemo_update_answer` | `updater::OPTION_UPDATE_DECISION` | no |
| `open_folder` | `main_open_folder` (desktop) — or keep Dart `_openRecordingFolder` | `ui.rs:973` (move to `ui_interface`) | no |
| `new_remote` → bool | Flutter already raises an existing tab; no binding needed | — | — |
| (none) | `session_capture_displays(Vec<i32>)` for the display subset (§5 R1) | `ui_session_interface.rs:850` | no |

Helpers currently living in `src/ui.rs` (secret filter, setup summary, peer reset, configured
api server, open_folder) move to `src/ui_interface.rs` so both front ends share them.

---

## 5. Feature inventory and port target

Legend — **Flutter today**: what exists in `flutter/lib`. **Target**: where it goes.
**And.**: Android applicability. Status column for tracking: ☐ open, ◐ in progress, ☑ done.

### 5.A Main window (`src/ui/index.tis`, `index.css`, `msgbox.tis`)

| # | Feature (what the user sees) | Sciter | Rust | Flutter today | Target | And. | ☐ |
|---|---|---|---|---|---|---|---|
| A1 | **Device-key gate**: no valid key → whole window is one card "Dieses Gerät ist noch nicht eingerichtet" + teal "Import setup string or device key"; nothing else visible; build id at the bottom; re-checked every 3 s | index.tis 1190-1216, App.render 1978-1984, 2111-2113, watcher 2973-3016 (2985-2992) | `common.rs:2774`, `ui_interface.rs:861` | none | new `common/widgets/nemo_gate.dart`, wraps desktop home + mobile home | yes (if phones are in the fleet) | ☐ |
| A2 | **Claim gate**: "Waiting for approval by your administrator" / "This device was not approved", outlined Import button, disappears when the admin acts | index.tis 1199-1230, 1988-1995 | `common.rs:2805`, set by poll | none | `nemo_gate.dart` | yes (needs poll) | ☐ |
| A3 | **Import setup string or device key** dialog: one unmasked field (setup string `tbfdesk-setup-v1:` or bare key), current fingerprint on top, "Load from file…" (`*.tbfsetup/*.txt/*.json`, ≤64 KB), helper text, empty keeps key, error keeps dialog open, all-or-nothing apply, then "Settings imported" summary ("ID server: x (was y)…", refused items, "already configured"), AB reload if signed in, gate re-renders | index.tis 646-762; opened from Settings row, menu 877, gates, login link 2020 | `nemo_setup.rs:106,116,240`, `ui_interface.rs:481/497`, `common.rs:2821,2847` | none | `common/widgets/nemo_import_dialog.dart`; mobile: file via SAF + **QR scan** (reuse `mobile/pages/scan_page.dart`) | yes | ☐ |
| A4 | **Sign-in screen** (required or on request): full-window card "Bitte melden Sie sich an"; Server field (prefill api-server → ID server → get_api_server → configured api server); "Allow insecure TLS (self-signed certificate)" (read-only line when fixed); username (Windows credentials hint), password with eye; Login, inline error; Cancel only if not required; certificate box; import link; Enter submits. Flow: POST `/api/login-key` → `nemo_seal_login` → POST `/api/login` `{sealed,id,uuid,type:'account',deviceInfo}` → open `sealed_access_token` (failure final) → 2FA/email unchanged. Server derivation: bare host → `https://host:21120`, sets custom-rendezvous-server, api-server, nemo-management-server (keeps same-host api-server). Required via `nemo-require-login` (poll). Old login modal removed | index.tis 1106-1160, 1232-1297, 2000-2024, 2099-2121, 2725-2736, submit 3018-3086 | `common.rs:2686, 3050`, `nemo_configured_api_server` | `common/widgets/login.dart:431` + `models/user_model.dart:178-180` (plain, OIDC, no server field) | replace `loginDialog` with `nemo_login_page.dart` (full-window when required, dialog otherwise); keep OIDC hidden unless server offers it | yes | ☐ |
| A5 | **Server certificate box**: "Checking…" dots → green (CA) / orange (self-signed, allowed) / red (blocked, no TLS, error); Subject, Issuer, SANs, SHA-256 fp in 8-byte groups, valid-until, allowed/blocked + hint; "Download certificate" (.crt PEM); fetched once per URL. Default: `allow-insecure-tls-fallback=Y` first time the gate shows if unset & not fixed | index.tis 1299-1475 | `common.rs:1825/1833` (`/api/tls-cert-info`) | only checkbox at `desktop_setting_page.dart:1741` | part of `nemo_login_page.dart`; mobile: share intent for .crt | yes | ☐ |
| A6 | **Account bar**: signed in → light-teal pill, display name bold teal (fallback username), outlined "Logout"; signed out → grey "Nicht angemeldet" + Login; ⋮ in the bar's corner; dark-theme colours. `@handle` not shown. Logout also clears local option `nemo-user-control-ticket` | index.tis 502-520, 2031-2045, 3145+, 3172-3183; css 583-639 | — | account only in Settings → Account (`desktop_setting_page.dart:2054-2077`), mobile `settings_page.dart:828` | desktop home left pane top; mobile: app bar / settings header | yes | ☐ |
| A7 | **⋮ menu**: Settings…, Open log folder, Copy recent log (redacted tail of main log + newest session log; header "TBFDesk ver (build) id ts", platform, service-log note; result/error dialog) | index.tis 1162-1188, 2708-2723 | `nemo_logs.rs:97,140` | none | desktop home; mobile: "Share log" in settings | partial | ☐ |
| A8 | **Settings as a modal dialog** with section cards sorted by row count, per-row plain-language tooltips (`NEMO_SETTING_TIPS` 1568-1617, translated), fixed rows greyed. Sections: **Permissions** (keyboard/mouse, clipboard, file transfer, camera, terminal, remote restart, TCP tunneling, block input (Win), LAN discovery, remote config modification); **Security & Network** (ID/Relay Server "(locked)", Management, Import setup string, IP whitelisting, Enable direct IP access + Port, Socks5/Http(s) proxy, WebSocket, Disable UDP (non-public), Allow insecure TLS fallback (non-public)); **General** (Enable service, RDP session sharing (Win, installed), Alias, Dark theme, Sync clipboard between sessions, Auto update (greyed, "(1 day) >", "not available yet"), Audio input, Enhancements (hwcodec, adaptive bitrate, remove wallpaper, keep awake), Language (flags), About, Change ID); **Password** (approve mode, one-time/permanent/both, set/clear permanent, OTP length 6/8/10, 2FA). Login/Logout not in Settings | index.tis 1478-1963, css 654-813 | — | tabbed `desktop_setting_page.dart`, mobile `settings_page.dart` cover most upstream rows | keep Flutter's settings page structure, **add** the missing rows and tooltips, **remove** privacy mode + Login/Logout + install nag; see A10-A12, A9 | partial (see §7) | ☐ |
| A9 | **Language picker**: only Deutsch (Deutschland) `de`, Deutsch (Österreich) `de-at`, English `en`, with drawn SVG flags; unset/"default" = de. Keys `nemo_lang_de`, `nemo_lang_de_at`, `nemo_lang_en` | index.tis 322-380, 1664-1672, 1906-1935; css 791-813 | `src/lang.rs` | full upstream list via `mainGetLangs` (`desktop_setting_page.dart:419/823`, mobile `settings_page.dart:805/1021`) | restrict list + flag widget (`common/widgets/nemo_lang_flag.dart`) | yes | ☐ |
| A10 | **ID/Relay Server dialog**: "Company network only" (`nemo-company-network-only`, requires ID server); exe-name lock message "Server settings are locked by this executable name." + licence; "…locked by management policy." when fixed; validation keeps dialog open | index.tis 135-145, 523-588 | `get_license`, `is_option_fixed`, `test_if_valid_server`, `ui_interface` guards | `common.dart:2900` ServerConfig, `:3540` setServerConfig, `mobile/widgets/dialog.dart:56` | extend both server dialogs | yes | ☐ |
| A11 | **Management dialog**: Management Server (http(s)), Public Key, "Enable management control" → `nemo-management-server/-public-key/-enabled` | index.tis 590-621, 875, 976+, 2743-2746 | `nemo_management_client.rs` | none | settings → Security | after §3 row 1 | ☐ |
| A12 | **Alias dialog**: `nemo-alias`, read-only + "managed by your administrator" when fixed | index.tis 623-644, 876 | — | none | settings → General | yes | ☐ |
| A13 | **Connect-time policy checks**: "Outgoing connections are disabled by TBF policy" (`nemo-outbound-enabled=N`), "Public network access is disabled by TBF company network mode" (`…@public` under exe lock / company-only), "Company network only requires an ID server", "Target is not allowed by TBF policy" (`nemo-outbound-targets`, `*` = all); Connect + Transfer buttons disabled when outbound off; "Already connected — nemo_already_connected_tip" | index.tis 147-216, 2078-2079 | `client.rs:205-224` also enforces | none (Flutter raises existing tab already) | `connect()` in `common.dart` pre-check + disabled buttons on desktop/mobile connection page | yes | ☐ |
| A14 | **"Direct access possible" hint** under the ID box: green bolt "Direct access possible — host:port"; second line "⚡ Knock :port · own key/fleet key" with tooltip; refresh every 1 s and on policy change | index.tis 2076, 2612-2613, 2632-2651, 2851-2860; css 337-353 | `nemo_direct.rs:198,205,220,229` | none | desktop `connection_page.dart`, mobile `connection_page.dart` | yes (needs poll) | ☐ |
| A15 | **Registration badge** after "Ready": bold "Registered" (green) / "Not registered" (orange) / "No device key" (orange) + tooltips; only if service running & status > 0; `setup_server_tip` link → plain text | index.tis 86-133; css 246-262 | `nemo_device_key_present`, `key_confirmed` | `desktop/pages/connection_page.dart:24-97` OnlineStatusWidget (links rustdesk.com) | extend OnlineStatusWidget + mobile | yes | ☐ |
| A16 | **Update banner**: no rustdesk.com link; `nemo_update_ready_auto` ("version {} will install itself…") + "Install now" → `nemo_update_requested`; or `nemo_update_ready_admin`; shown even if `disable_installation`; wraps | index.tis 2179-2199, 2060; css 478-495 | `nemo_update_state/now`, `NEMO_UPDATE_VERSION` overrides `get_new_version` | `desktop_home_page.dart:440-466` upstream | replace; see §2.3 | hide | ☐ |
| A17 | **Install nag removed; password pencil removed** (password settings only in Settings → Password) | index.tis 2059, 2402 | — | `desktop_home_page.dart:466` install_tip card; `desktop_setting_page.dart:1248-1271`, mobile `server_page.dart` | remove nag; keep pencil out | n/a / yes | ☐ |
| A18 | **About**: "About TBFDesk", version, fingerprint, Website/Support/Privacy rows from `NEMO_ABOUT_LINKS` (all empty → hidden), "Copyright © 2026 TBF GmbH" + licence, **"Based on the open-source RustDesk project."** (AGPL, never translated away); no upstream links / `Slogan_tip` | index.tis 895, 941-975 | — | `desktop_setting_page.dart:2403-2470`, mobile `settings_page.dart:213, 955-1098` | replace both | yes | ☐ |
| A19 | **Build id** "Build <id>" bottom-left with tooltip on main window and all gates | index.tis 1982, 1993, 2023, 2069; css 57-67 | `ui_interface.rs:861` | only `mainGetBuildDate` in About | home + gates + About | yes | ☐ |
| A20 | Auto-update interval label (dialog never wired) | index.tis 1077-1104 | `auto-update-check-interval` | Auto-update checkbox `desktop_setting_page.dart:542` | greyed row as in Sciter; drop the upstream checkbox | no | ☐ |
| A21 | **Address book auto-reload**: watcher compares local option `nemo-ab-version` every 3 s, reloads AB on change | index.tis 2994-3002 | poll sets it | none | `ab_model.dart` timer | yes (needs poll) | ☐ |
| A22 | Initial window size fits content (Windows) | index.tis 26-27, 2764-2827 | — | n/a | check Flutter default size with German labels | no | ☐ |
| A23 | Sciter robustness fixes (null guards, script blocks, BOM, script-error logging, CUR_SESSION, `--password-stdin/--password-file` H25) | various | `ui.rs peer_password_from_args` | n/a | H25 is CLI → check `core_main` path covers it for Flutter | — | ☐ |
| A24 | **Recording folder "Öffnen"** next to Incoming/Outgoing; resolved at click; created if missing; explorer on Windows (UNC ok); default folder ranking (local Videos → ProgramData → local → network) | index.tis 466-468, msgbox.tis 318-326 | `ui.rs open_folder`, `ui_interface.rs video_save_directory` | **already ported** (`desktop_setting_page.dart` `_openRecordingFolder`) | done; verify | no | ☑ |
| A25 | Direct-access port > 65535 rejected | index.tis 1063 | — | input filter `common/widgets/dialog.dart:309-311` | done | — | ☑ |
| A26 | **"Not authorized: <reason>"** refusal translated in two parts; validation errors keep dialogs open; `<select>` values collected | msgbox.tis 2-5, 187, 358-360 | `nemo_control` refusal text | none for the translation | `msgBox` in `common.dart` / `dialog.dart`: translate prefix + reason | yes | ☐ |
| A27 | **Terminal shell (Windows)** for console sessions on this computer: PowerShell (default, upstream order pwsh → Windows PowerShell → cmd) or Command Prompt; option `nemo-terminal-shell` = `''`/`cmd` on the CONTROLLED side, policy-settable, greyed when fixed. Decided by the service and passed to `--terminal-helper` as a 6th argument (the helper never reads config); the option is a choice, never a path. Operator 2026-11-06. Per-connection choice by the viewer needs an `OpenTerminal` proto field → follow-up once hbb_common is pushable | index.tis settings Permissions, kind `tshell` | `terminal_helper.rs` `nemo_terminal_shell_kind`/`shell_for_kind`, `terminal_service.rs` | `desktop_setting_page.dart` `_nemoTerminalShellRadios` (Windows only) | test on the Win11 VM: `ver` vs `$PSVersionTable` per value, both UIs set the same key | n/a | ☐ |

### 5.B Address book (`src/ui/ab.tis`)

| # | Feature | Sciter | Rust | Flutter today | Target | And. | ☐ |
|---|---|---|---|---|---|---|---|
| B1 | Empty AB sign-in prompt `nemo_ab_signin_tip` + Login (→ A4); without account feature "Please sign in to continue" | ab.tis 30-43; index.tis 2729; css 619-629 | — | upstream prompt in `common/widgets/address_book.dart` | use A4 | yes | ☐ |
| B2 | Tags pane on the **right**, peers left | ab.tis 64-76 | — | upstream layout | desktop AB layout | no | ☐ |
| B3 | ⟳ reload next to "Adressbuch" tab ("Reload address book from server") | ab.tis 3-4, 635; index.tis 3185-3187; css 640-653 | — | own refresh inside AB view | tab-bar icon | yes | ☐ |
| B4 | Search placeholder "Search ID or hostname", filter while typing | ab.tis 263, 276-280 | — | `peer_tab_page.dart:733-734` "Search ID" | change hint, verify hostname match | yes | ☐ |
| B5 | Empty AB text: "Empty" + "The server shared no computers with this account. Check … (ACL & Policy), then use the reload button above." | ab.tis 349-363 | — | none | AB empty state | yes | ☐ |
| B6 | Peer tile: "user@host" / host / user (never bare "@host"); green **"⚡ Direct" chip** when an endpoint exists + tooltip "Direct access possible — ep. Right-click for a direct-only connection."; combined tooltip; list tiles 270 px | ab.tis 8-14, 397-441; css 304-382 | `nemo_direct_endpoint` | none (`common/widgets/peer_card.dart`) | peer_card | yes | ☐ |
| B7 | Peer menu: **"Connect directly (no relay) — host:port"** (only with endpoint; one-shot `nemo_set_force_direct(id,true)`; consumed by `client.rs take_force_direct`); **"Connect via relay"** (one-shot `id + "/r"`); **"Reset preferences"** (confirm `nemo_reset_prefs_tip`; keeps password, info, alias, rdp_*/os-*; `nemo_reset_prefs_none` if nothing) | ab.tis 370-375, 459-466, 504-519 | `nemo_direct.rs:172`, `PeerConfig` | `peer_card.dart:739` only "Always connect via relay"; "Connect via relay" only in error dialog (`dialog.dart:1735`) | peer_card context menu (desktop) + long-press sheet (mobile) | yes | ☐ |
| B8 | **AB fetch sealed**: POST `/api/ab/get` with `nemo_ab_seal_fields(myid)` (`{sealed:"v1",id,device_key_pub,device_key_sig}`); if `nemo_sealed_request_enabled()` whole body + access_token wrapped by `nemo_seal_envelope`, **no Authorization header**; `sealed_data` opened by `nemo_unseal_ab` (failure final: "could not unseal the address book (device key mismatch?)"); own id filtered out | ab.tis 733-800 | `common.rs:2868, 2937, 2980, 3012` | `models/ab_model.dart` uses `/api/ab/personal`, `/api/ab/peers`, legacy GET `/api/ab` (`:1010`) | TBF path in `ab_model.dart` (keep upstream code path unreachable on TBF servers) | yes | ☐ |
| B9 | Session tabs **wrap** instead of truncating German labels ("Letzte Sitzungen | Favoriten | Im LAN erkannt | Adressbuch ⟳") | ab.tis 667-683; css 89-104 | — | `peer_tab_page.dart`, `models/peer_tab_model.dart:27-30` | check German widths desktop + phone | yes | ☐ |
| B10 | **Right-click "Terminal (command line only)"** (+ "Terminal (Run as administrator)" for Windows peers): a command line on the remote computer, no screen. Sciter opens it in the computer's own terminal window (`--terminal <id>` / `--terminal-admin <id>`, `src/nemo_console.rs`: same `ConnType::TERMINAL` session core as Flutter, raw VT bytes both ways, Windows child allocates its own console, Linux tries `$TERMINAL`, x-terminal-emulator, konsole, gnome-terminal, xfce4-terminal, kitty, alacritty, foot, xterm). Outgoing policy and the peer's "Enable terminal" apply as for any session. Operator 2026-11-06 | ab.tis `#terminal`, `#terminal-admin`; index.tis `createNewConnect`; ui.rs `nemo_open_console` | `nemo_console.rs` | upstream terminal page; menu labels aligned (no "(beta)") | scripted: console client in a pty echoes a nonce; Flutter `--terminal` + typed command; refused when the peer has terminal off | yes (upstream `mobile/pages/terminal_page.dart`; label check) | ☐ |

### 5.C Update prompt window (`src/ui/update.html`)

| # | Feature | Sciter | Rust | Flutter today | Target | And. | ☐ |
|---|---|---|---|---|---|---|---|
| C1 | 520×250 always-on-top window: `nemo_update_prompt_title`, `nemo_update_prompt_text` (version), countdown `nemo_update_countdown` (default 60 s, installs at 0), "Postpone" (only if allowed), "Now" | update.html 1-74; `ui.rs:197-208` | `updater.rs:382-435`, `OPTION_UPDATE_DECISION` | **none; prompt broken** (§2.2) | new Dart window + `core_main` route | no | ☐ |

### 5.D Small Sciter dialogs

| # | Feature | Sciter | Flutter today | Target | ☐ |
|---|---|---|---|---|---|
| D1 | EULA plain text, rustdesk.com/privacy handler removed | install.tis 19 | `install_page.dart:190-192` links rustdesk.com | remove link | ☐ |
| D2 | File size "1.5G" fix | file_transfer.tis 39-41 | own formatter | verify only | ☐ |
| D3 | "New RDP" translated | port_forward.tis 15 | — | verify | ☐ |

### 5.R Remote / session window (`remote.tis`, `remote.rs`, `header.tis`, `remote.html`)

| # | Feature | Sciter | Rust | Flutter today | Target | And. | ☐ |
|---|---|---|---|---|---|---|---|
| R1 | **View all displays tiled in one window** (`display_mode=all`): native video per display over one connection; layout by bounding box; tile mouse mapping; needs >1 display and peer ≥ 1.2.4 | remote.tis 111, 133-136, 423, 456-628; remote.html 10-27; remote.rs VideoSurfaces 39-49, on_rgba 611-647, VIDEO_BIND_RQ 827-870, set_view_all 1102-1126 | `Session::capture_displays` (`ui_session_interface.rs:850`), `refresh_video` (438), `switch_display` (863) | upstream "all monitors" `kAllDisplayValue` (`remote_toolbar.dart` `_MonitorMenu` 516, 652, 1499-1607; `desktop_render_texture.dart`) — **no subset**, no `session_capture_displays` FFI | reuse Flutter's per-display textures; add `session_capture_displays`; tile layout widget | no | ☐ |
| R2 | **Span**: one window across all local monitors, remote display i → local monitor i left-to-right; fallback proportional if counts differ; re-assert position after WM moves; toolbar centred on first monitor | remote.tis 141-171, 231, 273-341; header.tis 776 | as R1 | none ("use all my displays" opens windows) | `window_manager` bounds across monitors (`screen_retriever`) | no | ☐ |
| R3 | **One window per remote display**, each **maximized** on its own monitor (work area: local taskbar stays visible, title bar for restore/resize — operator 2026-11-09, client `b194e9359` on `nemo-display-windows-workarea`, Sciter + Flutter), same connection; closing one → back to "all" | remote.tis 343-416; remote.rs DISPLAY_WINDOWS 72-344, open/close_display_window 1132-1195 | as R1 | upstream "show displays as individual windows" + `openMonitorInNewTabOrWindow` (`remote_toolbar.dart:739`) | add auto placement per monitor + fallback | no | ☐ |
| R4 | **Display-mode segmented control** (single / all \| span / windows; multi-monitor modes greyed on 1 monitor with tooltip) + **subset picker** for ≥3 displays ("n/N", last one can't be unticked); per-peer `nemo-displays-shown`, `nemo-display-mode`; restore saved mode 1.2 s after first peer info; display chip click in multi mode → single; `\` cycling only in single | header.tis 11-41, 160-237, 401-436, 631-673, 790; remote.html 32-72; remote.tis 176-218; lang `nemo_mode_*`, `nemo_display`, `nemo_pick_*` (en.rs 305-312) | peer options | none | `remote_toolbar.dart` monitor menu | picker only | ☐ |
| R5 | Header auto-hide/reveal over tiles | remote.tis 261, 654-674 | — | Flutter toolbar differs | n/a unless needed | no | ☐ |
| R6 | **Direct / Relay text badge** (green "Direct", orange "Relay") in the toolbar | header.tis 175, 184; header.css 42-58 | upstream `setConnectionType` | icon in tab (`remote_tab_page.dart:160-164`, `shared_state.dart:77/110`) | text chip in toolbar; mobile toolbar too | yes | ☐ |
| R7 | **Clipboard sync between controller sessions** (`allow-sync-clipboard-between-sessions`) | clipboard.rs 17-42, 268, 409-419, 586-634 | per-process instance id | never fires in one-process Flutter | design: in-process broadcast to sibling sessions (§6) + Settings toggle | no | ☐ |
| R8 | **Privacy mode removed** (driver not shipped) | header.tis 299 | — | `toolbar.dart:765-816`, `remote_toolbar.dart:999-1018`, `desktop_setting_page.dart:1108-1110, 1984-2008`, mobile | remove/hide everywhere | yes | ☐ |
| R9 | **Custom quality slider minimum 1 %** (was 10); "Bitrate"/"More" translated | header.tis 561 | — | `kMinQuality=10` (`consts.dart:260`; `setting_widgets.dart:16,55`; `dialog.dart:1884`) | set 1 | yes | ☐ |
| R10 | Image quality shows **"low"** when unset | header.tis 583 | check hbb_common default | — | match the stored default | yes | ☐ |
| R11 | Toolbar tooltips; "Auto" codec translated | header.tis 177, 186-190, 283 | — | Flutter has tooltips | verify German | yes | ☐ |
| R12 | **Remote cursor shape in every display mode** (single / all / span / windows). The 4b3d91476 "fix" (undeclared `first_mouse_event_triggered`) had a false premise — TIScript reads it as undefined, updateCursor always ran — and is reverted (ee4115220). The real bug: in all/span/windows the cursor was set on the session `<video>` only, tiles and display windows showed the local arrow — fixed in Sciter by 124921284 (`applyTileCursors`, `set_display_windows_cursor`); lab 0 failures in all modes (Linux + Windows inline) | remote.tis `updateCursor`, `applyTileCursors`, `applyDisplayWindowsCursor`; remote.rs `set_display_windows_cursor` | — | `model.dart` CursorModel, `remote_page.dart` MouseRegion; span draws the cursor per tile (f592940e6) | **Linux lab 2026-11-06: Flutter and Sciter 0 failures in all 4 modes** (88 points each, 9 cursor shapes, both monitors), held-button cursor ok in both; Windows run: see LAB.md | yes | ◐ (Windows pending) |
| R13 | Keyboard grab hold, CUR_SESSION | remote.tis 642-650; remote.rs 858-864 | — | n/a | — | — | — |
| R14 | Default view style "shrink" until chosen per peer | — | `ui_session_interface.rs:238-254` | automatic | verify Flutter default-view-style setting behaviour | n/a | ☐ |
| R15 | **Remote mouse dead after connect on a static remote screen** (Flutter): first frame drawn before peer info was handled → `waitForFirstImage` re-armed → full-window `emptyOverlay` swallowed every pointer event until the next frame | — | `flutter.rs` VideoRenderer `rendered_size`, `set_size` re-announces an already shown frame (ce4c55ae5) | was broken | lab input 11 ms in all modes | yes | ☑ (Linux) |
| R16 | **"windows" mode / main-window calls behind the device-key gate** (Flutter): the gate replaced the home page, which registers the main window's multi-window handler → no window for display 2 (MissingPluginException) | — | — | `nemo_gate.dart`: home page mounted behind the gate (offstage, IgnorePointer, ExcludeFocus) (ce4c55ae5) | lab windows mode 0/32, 2 windows | n/a | ☑ (Linux) |
| R17 | **No keyboard when the session window opens under the mouse** (both UIs, Linux): grab requested before the grab loop existed, owner recorded, never re-sent | — | `keyboard.rs` start_grab_loop re-applies the owner's grab (03cc80dd6; Sciter branch 5e691beb8) | same code | lab input test: 41/41 (Flutter), Sciter 39/41 (R18) | n/a | ☑ (Linux) |
| R18 | Horizontal wheel (tilt wheel / sideways touchpad) | libsciter-gtk reports it as vertical (Linux) — engine limitation, accepted | — | works | lab input test | n/a | — (Sciter Linux limitation) |

---

## 6. Design notes for the hard parts

- **R7 clipboard sync between sessions.** Sciter: one process per session, a process-local
  instance id marks "came from a sibling". Flutter desktop: all sessions in one process (or
  one per window via multi-window, but sharing the Rust core). Option: in `clipboard.rs`, when
  a session receives remote clipboard content and the option is on, publish it to the other
  live sessions of the same process instead of relying on the OS clipboard round-trip; keep
  the origin session id in the owner marker so it is not echoed back.
- **R1-R4 display modes.** Flutter already renders multiple displays as separate textures
  (`desktop_render_texture.dart`) and supports multi-window per display; what is missing is
  (a) a subset (`capture_displays`), (b) span geometry, (c) per-monitor placement, (d) the
  mode control + persistence. Reuse the peer option names so a user's saved mode survives the
  switch from Sciter.
- **Login gate + device-key gate** wrap the whole home page on desktop and mobile: a top-level
  widget that watches `main_nemo_device_key_present`, `main_nemo_claim_status`,
  `nemo-require-login` + logged-in state every 3 s and swaps the child. Same order as Sciter:
  device key → claim → login → home.
- **Android provisioning**: QR code of the setup string is the natural input; the same string
  as text/file must also work. After apply, start the management client (§3 row 1).
- **Settings page**: keep Flutter's tabbed settings (it is the upstream UX the move is buying)
  but carry over the tooltips, the fixed-row greying, and the TBF rows. Do not reproduce the
  Sciter modal-overlay layout.

---

## 7. Branding / text cleanup in Flutter

- Window title: `common.dart:2996` `getWindowName` (`mainGetAppNameSync`) — reads TBFDesk now
  that `APP_NAME` is TBFDesk; verify.
- About: desktop `desktop_setting_page.dart:2439/2447/2465/2469` (rustdesk.com links, Purslane
  copyright, `Slogan_tip`); mobile `settings_page.dart:38, 955, 980, 1093` → A18.
- Download / update link `desktop_home_page.dart:440/456` → A16.
- Privacy link `install_page.dart:190` → D1.
- Pricing link `connection_page.dart:44`, `setup_server_tip` link `:97` → plain text (A15).
- Mobile `connection_page.dart:127` rustdesk.com/download → remove.
- App icons / names for Android (`flutter/android/app/src/main/AndroidManifest.xml`,
  `res/mipmap*`, `applicationId`) — Layer 3 of RENAMING-PLAN for mobile; decide package id.
- Keep **"Based on the open-source RustDesk project."** visible (AGPL).

---

## 8. Phases (order of work on `nemo-tdd-flutter`)

1. **P0 — safety (§2)**: shared secret filter/re-inject for the option API; update prompt route
   + Dart window; replace the unverified manual update path; sealed login (also needed by P2).
2. **P1 — FFI layer (§4)**: all `main_nemo_*` wrappers, helpers moved from `ui.rs` to
   `ui_interface.rs`, codegen. No UI yet. Unit tests for the moved helpers.
3. **P2 — provisioning & login (A1-A5, A19, A26, B1, B8)**: gates, import dialog, sign-in page
   with certificate box, sealed AB, refusal translation, build id. Desktop + mobile.
4. **P3 — main window & settings (A6-A18, A20-A21, B2-B7, B9, D1-D3, §7)**: account bar, ⋮
   menu, settings rows/tooltips/removals, language flags, server/management/alias dialogs,
   policy checks, direct hint, registration badge, update banner, About, AB layout & menu.
5. **P4 — remote window (R1-R11, R14)**: display modes + picker, Direct/Relay badge, privacy
   removal, quality minimum, clipboard sync (R7).
6. **P5 — Android backend activation (§3)**: compile + start the management client on
   Android, ungate session revocation, logs share, decide on lock-after-session-end.
7. **P6 — packaging**: Windows installer/updater for the Flutter build (the updater
   `update_to` path and `install_me` must handle the Flutter bundle layout: `data/`,
   `flutter_windows.dll`, `librustdesk.dll`), Linux `.deb`/Arch, Android APK id/icon.
   Cut-over decision: Sciter build stays the shipped one until P0-P4 pass the lab checklist.

Every phase: no merge to `nemo-tdd` until its rows here are ☑ and its lab checks pass.

---

## 9. Verification

- **Static**: `dart analyze` on `flutter/lib`; `cargo check --features flutter` (desktop) and
  `cargo ndk … --features flutter` (Android) — compile-only on the dev box.
- **Unit**: tests for moved helpers (secret filter never returns `nemo-device-key`;
  set_options keeps it; managed-state restore), setup apply summary, AB unseal failure path.
- **tests/gui** (lab VMs): extend the existing Windows/Linux GUI stages for the Flutter binary:
  device-key gate visible on a fresh profile; import setup string → gate gone, ID server set;
  sealed login against the lab hbbs; AB lists shared peers and excludes self; ⚡ chip and
  "Connect directly" on a peer with an endpoint; update prompt appears and Postpone works;
  settings save keeps the device key (read the toml).
- **Android** (emulator + one real phone): QR import, sealed login, AB, outgoing session with
  control ticket accepted by a ticket-requiring host, direct endpoint used when published,
  refusal message translated.
- **Parity sweep**: walk every row of §5 against the Sciter build side by side (German UI),
  screenshot both, tick the row.

---

## 9b. Android — plan only (NOT being implemented now; operator decision 2026-11-02)

Desktop (Windows + Linux) is ported first. Android is documented here so nothing is lost;
tracked as OPEN-TODOS #51. All file:line refs are `nemo-tdd-flutter`.

**What already works on Android once built** (shared Rust, no work): rendezvous hardening
and fail-closed secure TCP; outbound/company-network checks at connect time; Ctrl+Alt+Del /
Ctrl+Alt+End → SAS from a hardware keyboard; audio channel guard; German default language;
the new `main_nemo_*` FFI functions (they compile for Android; desktop-only ones return
"not supported").

**A1. Backend activation (Rust)**
1. `src/lib.rs:41-45` — compile `nemo_management_client` on Android too (drop
   `not(any(android, ios))`, keep the feature gate).
2. `src/server.rs:599-603` (mobile `start_server`, reached from
   `Java_ffi_FFI_startServer`, `flutter_ffi.rs` ~3043) — call
   `nemo_management_client::start()`. iOS (client only): start it from
   `flutter_ffi.rs` `initialize()` instead.
3. `nemo_management_client.rs:255` — ungate the `terminate_all_authed_sessions` call
   (the function at `connection.rs:5864` is ungated) so a server cut ends Android-hosted
   sessions.
4. Check the poll's other dependencies on Android: `set_permanent_password_with_result`
   has an android branch (`ui_interface.rs:737-741`), `refresh_options` is a no-op,
   `nudge_updater` is win/linux-only (`:799`) — expected to compile; verify with
   `cargo ndk … --features flutter`.
5. Config location: the service and the UI are ONE process on Android
   (`platformFFI.syncAndroidServiceAppDirConfigPath`), so `apply_setup` can write
   directly; `ui_interface.rs:497` (android `nemo_set_provisioned_options`) is the hook.
6. `nemo_logs` (`lib.rs:57`): ungate, add an Android branch to `open_folder`
   (`nemo_logs.rs:142-147`) or skip it and expose only `collect` → "Share log" intent.
7. Updater (`lib.rs:80`): stays off. Distribution via MDM / store / APK push; hide every
   update banner on Android (`mobile/pages/connection_page.dart:88,121-127`
   `_buildUpdateUI` links rustdesk.com/download — remove).
8. Lock after session end on an Android HOST (`connection.rs:4800-4810`,
   `lock_screen` gated not(android)): needs DevicePolicyManager.lockNow via JNI
   (device-admin permission) — decision 10.3.

**A2. Provisioning on the phone (Dart, `flutter/lib/mobile/`)**
- Device-key gate + claim gate (A1/A2) wrapping `mobile/pages/home_page.dart`, if phones
  are fleet devices (decision 10.1).
- Import dialog (A3) with three inputs: paste, file (SAF picker, ≤64 KB), and **QR scan**
  of the setup string — reuse `mobile/pages/scan_page.dart` (it already scans server
  config); detect `tbfdesk-setup-v1:` with `mainNemoIsSetupString`.
- After a successful import: start/restart the management poll (A1.2), reload AB.

**A3. Login + address book (shared Dart, mobile layouts)**
- Sealed login page (A4) incl. certificate box (A5; "Download certificate" → share
  intent) replacing `common/widgets/login.dart` on mobile too.
- Sealed AB fetch (B8), empty-state text (B5), reload (B3), search hint (B4), peer
  long-press sheet with Connect directly / Connect via relay / Reset preferences (B7),
  ⚡ Direct chip on peer cards (B6), AB auto-reload on `nemo-ab-version` (A21).
- Account header (A6) in `mobile/pages/settings_page.dart:828` area; logout clears
  `nemo-user-control-ticket`.

**A4. Settings on the phone (`mobile/pages/settings_page.dart`)**
- Add: Alias (A12), Management (A11, after A1), Import setup string, ID/Relay server
  company-network-only + lock messages (A10, `mobile/widgets/dialog.dart:56`), language
  picker restricted to DE/AT/EN with flags (A9; `settings_page.dart:805,1021`), build id
  (A19), About TBFDesk with AGPL line (A18; `settings_page.dart:38,213,955-1098`).
- Remove: privacy mode, rustdesk.com links, the upstream update check toggle
  (`settings_page.dart:73,183-187,598-605`).
- Not applicable: RDP sharing, block input, audio input device, remove wallpaper,
  enable-service toggle (Android has its own start-service flow).

**A5. Session UI on the phone (`mobile/pages/remote_page.dart`, `common/widgets/toolbar.dart`)**
- Direct/Relay badge (R6), privacy mode removed (R8 — `toolbar.dart:765-816` is shared
  with desktop, so the desktop removal covers it), quality minimum 1 % (R9), refusal
  "Not authorized: <reason>" translated (A26), display subset picker only (R4; no span /
  windows modes).
- Connection status on `mobile/pages/connection_page.dart`: registration badge (A15),
  direct hint (A14), outbound policy checks (A13).

**A6. Packaging**
- Package id / app name / icon (RENAMING-PLAN Layer 3 for mobile — decision 10.2):
  `flutter/android/app/build.gradle` `applicationId`, `AndroidManifest.xml` label,
  `res/mipmap*`, the accessibility-service label (`[RustDesk Input]` string, OPEN-TODOS
  #18 note).
- Signing key and distribution channel.

**A7. Verification (when implemented)**
Emulator + one real phone: QR import → gate gone, ID server set; sealed login; AB lists
shared peers and not itself; outgoing session to a ticket-requiring host accepted;
direct endpoint used when published (knock seen on the host); refusal text translated;
Android-hosted session cut from the dashboard ends it; settings save keeps the device key.

## 10. Decisions (operator, 2026-11-02)

**Desktop**
- Settings: Flutter's tabbed settings page kept (not the Sciter modal dialog).
- OIDC: off on desktop/mobile (web only). **Azure AD / Entra ID sign-in = future TODO**
  (OPEN-TODOS #54) for desktop, Linux, Android and iOS.
- Cut-over from Sciter to Flutter desktop: after the lab video run (#52), done on a separate machine.

**Mobile (Android + iOS)**
1. **Fleet is optional.** Default = standard (no device key, no gate) so any phone can be
   helped. Optional fleet mode = device key imported (paste / file / QR) → same gates and
   policy features as desktop. Server side: when "require device key" is on, a **device
   allow-list** lets listed IDs (the phones) register and be controlled without a key
   (OPEN-TODOS #53, server repo). Client rule: the device-key gate is shown on mobile only
   when the client is in fleet mode (a key or a setup string was imported, or the server
   reports it requires a key for this ID).
2. **Controller AND controlled.** Goal: fix a user's phone remotely. Android: screen capture
   (MediaProjection) + input via the Accessibility service, as upstream — no device-admin
   needed. iOS: **controller only** — Apple allows no third-party remote input, and RustDesk's
   iOS app cannot share its screen; an iPhone can be viewed at most via a ReplayKit broadcast
   extension (not in upstream; separate TODO if wanted).
3. Lock after session end on Android: not implemented. Revisit only if device-admin turns out
   to be required for control (it is not for capture + input).
4. **Everything renamed to TBFDesk**: app name, package id, icons, accessibility-service
   label, notification texts, URI scheme `tbfdesk://`, iOS bundle id + display name.
5. Distribution: private APK (own signing key); store costs documented below.
6. Signing: own Android signing key, held offline by TBF (see below).
7. Provisioning input: paste, file (SAF picker), QR scan of the setup string.
8. Sign-in: same sealed username/password flow as desktop; Azure AD = TODO (#54).
9. Management client: polls only while the app runs (no background service for it).
10. **Android 17 (API 37) is the minimum AND the test device (Pixel 7a)** — operator,
    2026-11-02. Client `28ffdb6dc`: minSdk/targetSdk/compileSdk 37 in
    `flutter/android/gradle.properties`. Phones below Android 17 cannot install the app.
    Build risk: AGP 7.3.1 / Gradle 7.6.4 predate API 37 — the first Android build must
    confirm; otherwise upgrade AGP (8.x+) and Gradle.
11. Logs: "Share log" through the Android/iOS share sheet → mail, Teams, Webex, Telegram,
    WhatsApp, Signal or any installed app (Flutter `share_plus`).
12. Settings: hide only desktop-only items (RDP sharing, block input, audio input device,
    remove wallpaper, enable-service toggle); keep everything useful on a phone.
13. Display: only modes that make sense with one local screen — single display + picker of
    the remote displays; no span / one-window-per-display.
14. **iOS: SHELVED** (operator, 2026-11-02 — deployment too complicated for now). Code stays
    iOS-safe (bundle id at.tbf.tbfdesk, controller-only, mgmt client from init), upstream's
    unused Firebase plist removed (`28ffdb6dc`). Apple Developer account + team id: future.
15. Start: Android/iOS work starts now (desktop P0-P4 done); lab videos on another machine.

**Distribution and signing (answers)**
- *Signing key*: every APK is signed with a private key in a keystore file (`.jks`, RSA 4096,
  created once with `keytool`). Android installs an update only if it is signed with the SAME
  key as the installed app — lose it and every phone must uninstall/reinstall; leak it and
  anyone can ship a "TBFDesk update". Keep it offline (encrypted, two copies), never in git or
  on the build server; sign release builds on a trusted machine. With Google Play, "Play App
  Signing" lets Google hold the app key and TBF only an upload key (recoverable if lost).
- *Costs*: Google Play — one-time US$25 developer registration, no yearly fee; private
  distribution to your own organisation via Managed Google Play costs nothing extra.
  Apple — Apple Developer Program US$99/year, **required for iOS in any case** (also for
  TestFlight / private "custom apps" via Apple Business Manager). Private APK: no store fee.
- *MDM* (Mobile Device Management, e.g. Microsoft Intune, VMware Workspace ONE, Google
  endpoint management): the company manages its phones centrally — installs and updates apps,
  pushes app configuration (e.g. the setup string) and policies. Optional for TBFDesk; only
  useful if the phones are company-managed.


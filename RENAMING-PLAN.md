# TBFDesk — Complete Rename Plan (RustDesk → TBFDesk) without breaking installs

**Status:** PLAN (not yet executed). **Current safe state:** user-visible text = **TBFDesk**; internal `APP_NAME` = **RustDesk** (so config dir / service / registry / protocol are unchanged and nothing breaks). This doc is how to finish the job — flip the internal identity too — as **one coordinated, migration-safe release**.

## Why it's deferred by default
`APP_NAME` (`libs/hbb_common/src/config.rs:111`) is the single anchor; **50+ sites derive from it** at runtime. A blind rename orphans every existing install's config, the installed Windows service, the registry, and upgrade-in-place. So the rename is not a find-replace — it's a constant change **plus a migration**.

## Blast radius — everything `APP_NAME` drives (must all move together)
- **Config + data dirs:** `%APPDATA%\RustDesk` (Windows), `~/.config/RustDesk` / `ProjectDirs` (`config.rs:785`), log dirs (`:806/:813/:820`), `/tmp/RustDesk` (`:857`). Holds the device **ID, permanent password, all settings** — losing this = users re-register with a new ID.
- **Windows service + install:** service dispatcher/handler (`platform/windows.rs:533/654`), registry subkey (`:1341` `get_subkey`), Program Files install dir (`:1358/:1416`), uninstall/run/scheduled-task entries, `rustdesk.exe` name (`:1452/:3933`), ~30 more `get_app_name()` sites.
- **macOS:** `.app` bundle + plist templating (`platform/macos.rs:310-311/360/809/960`), bundle id `com.carriez.rustdesk` (`Cargo.toml:237`).
- **Linux:** `rustdesk.desktop`, tray exe (`platform/linux.rs:702-714/1687`).
- **Packaging:** crate `name = "rustdesk"` (`Cargo.toml:2`), `librustdesk` (`:12`), bundle `name = "RustDesk"` (`:236`).
- **Protocol URI:** `rustdesk://` (`common.rs:1014` `get_uri_prefix`).
- **Identity helpers:** `common.rs:1004 get_app_name`, `:1009 is_rustdesk`, `:2313 is_custom_client` (compares `== "RustDesk"` — note: after the rename `is_custom_client()` flips to **true**, which re-enables "Powered by" / customized-edition branches — audit those), `:1018 get_full_name`.

## What is NOT affected (roll out gradually, no compat break)
The **peer/relay wire protocol, `licence_key`, and peer keys do not depend on `APP_NAME`.** A renamed TBFDesk client and an un-renamed RustDesk client interoperate at the protocol level. So the fleet can be migrated machine-by-machine.

## The rename in layers
### Layer 1 — flip the constant
`config.rs:111` `APP_NAME` `"RustDesk"` → `"TBFDesk"`. This alone re-points config dir, service name, registry subkey, install path, exe name, `/tmp`, and logs to `TBFDesk`.

### Layer 2 — MIGRATION for existing installs (the critical, must-not-skip part)
Add to the installer/first-run path (`platform::run_after_install`, `core_main.rs --after-install`, and a first-run check):
1. **Config/data dir:** if the new dir (`%APPDATA%\TBFDesk` / `~/.config/TBFDesk` / macOS `~/Library/…/TBFDesk`) is absent **and** the old `RustDesk` dir exists → **copy** it over (keep the old until the new is verified). Preserves ID, permanent password, all settings.
2. **Windows service:** stop + uninstall the old `RustDesk` service, install the new `TBFDesk` service (so it keeps capturing the login/UAC/lock screen). Do it silently in `run_after_install`.
3. **Registry:** migrate `HKLM/HKCU\…\RustDesk` → `…\TBFDesk` (uninstall entry, Run key, stored settings).
4. Make every step **idempotent** and safe to re-run.

### Layer 3 — packaging / bundle identifiers
- `Cargo.toml` bundle `name` → `TBFDesk`; bundle `identifier` `com.carriez.rustdesk` → `com.tbf.tbfdesk`. **macOS caveat:** changing the bundle id makes the OS treat it as a new app (breaks in-place/Sparkle upgrade) — plan a signed migration/first-install.
- Crate `name = "rustdesk"` → **optional / KEEP**. It's invisible to users, and renaming it churns hundreds of internal references + the `librustdesk`/service target names. Recommend leaving the crate name as-is; rename only user-facing packaging.

### Layer 4 — protocol URI scheme
`rustdesk://` → `tbfdesk://` (`common.rs:1014`). Register the new scheme; if any deep links are in use, **keep `rustdesk://` registered too** during a transition window.

### Layer 5 — audit `is_custom_client()` flips
Because `is_custom_client()` becomes **true** after the rename (`common.rs:2313`), re-check every `is_custom_client`-gated branch (e.g. the "customized edition / contact your administrator" update text, `powered_by_me`) so nothing unwanted turns on.

## Rollout procedure
1. Build a TBFDesk-named client **with** the Layer-2 migration wired into first-run/after-install.
2. **Test on a machine that already has a RustDesk-named install:** confirm ID + permanent password + settings are preserved, the old service is replaced by the new one, and the new service still captures the login screen.
3. Roll out fleet-wide via the **server-driven update mechanism** (see OPEN-TODOS #1) — that lets you push + verify migration centrally. Until that exists, a one-time manual/GPO push.
4. Keep any host-side tooling (systemd unit names, packaging scripts) consistent with the new name.

## Risks & rollback
- **Failed migration = fresh empty config** → user re-registers (new ID), lost saved password. Mitigate: idempotent + verified migration; keep the old dir until the new is confirmed good.
- **macOS bundle-id change** breaks in-place upgrade — needs a signed migration/first-install.
- Treat the rename as **one-way**: once users are on `…\TBFDesk`, reverting needs the reverse migration. Test exhaustively before fleet rollout.

## Recommendation
Do the full rename as **one coordinated release, after the server-driven update feature exists** (so migration can be pushed and verified centrally). Until then, the current split — **user-visible TBFDesk, internal RustDesk** — is the correct, non-breaking state and requires no action.

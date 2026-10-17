# TBFDesk — Complete Rename Plan (RustDesk → TBFDesk) without breaking installs

**Status: Layers 0, 1, 2, 4 and 5 are DONE (2026-10-17, client `cfbf275a4` + hbb_common
`40b4e27`). Layer 3 (packaging / bundle ids) is the only one left.** `APP_NAME` is
`TBFDesk`, so the config directory, the Windows service, the registry key, the install
directory, the exe file name, the IPC pipe, the logs and the URI scheme all say TBFDesk —
and an existing RustDesk-named install is migrated rather than orphaned. The sections
below are kept as the record of what each layer covered and what was deliberately left.

The text that follows describes the state **before** that release; each layer now carries
a DONE block with what actually shipped.

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
### Layer 0 — the display name only (NO migration, do this first)  *(added 2026-10-16, OPEN-TODOS #17)*
"User-visible text = TBFDesk" above is true only *inside* the app's own UI. Every **OS-level** label still says RustDesk, and those are exactly what Windows Search indexes — so an installed client is not findable as "TBFDesk" (reported from the Windows test workstation). Fixable without touching `APP_NAME`, because none of the searched surfaces are the config dir, the service or the registry key *name*:
- introduce `get_display_name()` → `"TBFDesk"` (new constant; `APP_NAME` unchanged) and use it only for shortcut labels (`platform/windows.rs:1572/1591/1622-1623`), the uninstall `DisplayName` **value**, the window title and the tray tooltip;
- set `ProductName` / `FileDescription` / `OriginalFilename` explicitly in `build.rs:41-47` — today they fall back to winres defaults, i.e. `Cargo.toml` `name = "rustdesk"` / `description = "RustDesk Remote Desktop"`;
- the installer must **delete the old `.lnk` names**, or an upgraded machine shows both entries.

Doing Layer 0 first gets the searchable name with none of the migration risk below.

**Layer 0 is DONE (2026-10-16, client `nemo-tdd`).** `get_display_name()` / `DISPLAY_NAME`
in `common.rs`; shortcut file names, the Start-menu folder, the uninstall `DisplayName`
and `Publisher` now use it; `build.rs` sets `ProductName` / `FileDescription` /
`OriginalFilename` / `CompanyName` explicitly; the installer deletes the old `.lnk` names
and the old Start-menu folder (and so does the uninstaller, for both names), so an
upgraded machine does not show two entries. Window title and tray tooltip already read
TBFDesk. `APP_NAME`, the config dir, the service name, the registry key name, the exe
file name and the URI scheme are untouched — Layers 1–5 below are still open.
**VERIFIED on Windows 2026-10-17** (test VM, packaged installer built from client
`83d505e2b`): Start menu `Programs\TBFDesk\TBFDesk.lnk` + `Uninstall TBFDesk.lnk` +
`Startup\TBFDesk Tray.lnk`, desktop `TBFDesk.lnk`, Apps & Features **TBFDesk /
TBFDesk / 1.4.7**, and the exe's version info — what Windows Search and Explorer's
Description column actually read — `ProductName TBFDesk`,
`FileDescription "TBFDesk Remote Desktop"`, `OriginalFilename TBFDesk.exe`,
`CompanyName "TBF GmbH"`. The service is still registered as `RustDesk` and the config
still lives in `%APPDATA%\RustDesk`, which is Layer 0 working exactly as designed.

### Bucket triage for OPEN-TODOS #18 (what "remove RustDesk" does and does not cover)
Done 2026-10-16 as **bucket 1 — user-visible labels** (client `nemo-tdd`):
- `src/lang/*.rs`: **892 translated VALUES** across 49 locales renamed to TBFDesk. Keys
  are the lookup strings used throughout the code and are never touched — which is also
  why three of them (`About RustDesk`, `Keep RustDesk background service`,
  `Show RustDesk`) showed the old name in English and German: their value was empty or
  missing, so `translate()` fell back to the key. They now have values.
- Kept on purpose: the AGPL attribution `Based on the open-source RustDesk project.`
  (key *and* value), and the two `rustdesk.com/docs/...` links, which are upstream
  documentation that genuinely explains those OS permission steps.
- `res/`: display fields only — `.desktop` `Name` + `Keywords`, `rustdesk.service`
  `Description`, `PKGBUILD` `pkgdesc`, the four rpm specs' `Summary` and `%description`.
  `Exec`, `Icon`, `StartupWMClass`, `MimeType`, `pkgname`, rpm `Name` and every path
  stay: they are identity (bucket 2).
- `flutter/lib/desktop/widgets/tabbar_widget.dart`: one hard-coded window label.

Deliberately NOT changed, with the reason:
- **`res/msi/`** — the MSI build is parameterised: `preprocess.py --app-name` substitutes
  `RustDesk` → the given name across the `.wxs`/`.wxl` files, *including the service name
  and paths*. Hard-coding TBFDesk in those files would be a bucket-2 identity change
  dressed up as a label change. An MSI build must pass `--app-name` instead. We ship the
  exe installer (`install_me`), so nothing in the deployment depends on this today.
- **`res/DEBIAN/*`** — maintainer scripts; every occurrence is a path or the service name.
- **`src/platform/*`, `src/ui/*`, `Cargo.toml`** — the remaining matches are `APP_NAME`
  consumers, the crate name, and the `rustdesk`/`librustdesk` library names. Bucket 2/3.
- **Our own docs and scripts** (`DEPLOY.md`, `DEPLOYMENT-STEP-BY-STEP.md`, `HANDOFF*.md`,
  `RUNBOOK-LOCAL-MODEL.md`, `LAB-VERIFICATION-*.md`, `UPSTREAM-SYNC.md`, `e2e/*.ps1`,
  `scripts/vm-apply-server-address.sh`, `build-client-fast.cmd`) — audited line by line:
  what is left is `%APPDATA%\RustDesk`, `RustDesk2.toml`, `RustDesk.exe`,
  `/tmp/RustDesk-<uid>`, `~/.local/share/logs/RustDesk/`, the `FOCUS RustDesk` window
  class, the `/projects/rustdesk/...` host paths, and discussion of the upstream project.
  Those are bucket 2 and 3: renaming them in the docs **before** Layer 2 ships would
  make the runbooks wrong, which is exactly what #18 warns against. The prose already
  says TBFDesk everywhere.
- **Android**: the accessibility-service label the `android_input_permission_tip2` /
  `[RustDesk Input]` strings point at is still derived from `APP_NAME`, so on Android the
  tip now names TBFDesk while the system list shows RustDesk Input. Harmless here (no
  Android client is deployed) and it resolves itself at Layer 1.

### Layer 1 — flip the constant
`config.rs` `APP_NAME` `"RustDesk"` → `"TBFDesk"`. This alone re-points config dir, service name, registry subkey, install path, exe name, `/tmp`, and logs to `TBFDesk`.

**DONE 2026-10-17.** `APP_NAME` is initialised from a new `DEFAULT_APP_NAME` constant, and
`LEGACY_APP_NAME = "RustDesk"` is a constant too, so the code that has to find and clean
up the old name does not carry the literal around.

One site the plan did not list and that decides whether the install works at all:
**`install_me` never renamed the copied exe.** The installer XCOPYs the folder it is
running from, so the file lands under its SOURCE name — `rustdesk.exe`, because the crate
is still called rustdesk (Layer 3 keeps it) and the packer extracts it under that name —
while the service, the shortcuts, the UninstallString and the URI handler registered by
the same script all point at `{path}\{APP_NAME}.exe`. Those agreed only while the two
words were the same. `install_me` now calls `rename_exe_cmd`, which `update_me` always
did.

### Layer 2 — MIGRATION for existing installs (the critical, must-not-skip part)
Add to the installer/first-run path (`platform::run_after_install`, `core_main.rs --after-install`, and a first-run check):
1. **Config/data dir:** if the new dir (`%APPDATA%\TBFDesk` / `~/.config/TBFDesk` / macOS `~/Library/…/TBFDesk`) is absent **and** the old `RustDesk` dir exists → **copy** it over (keep the old until the new is verified). Preserves ID, permanent password, all settings.
2. **Windows service:** stop + uninstall the old `RustDesk` service, install the new `TBFDesk` service (so it keeps capturing the login/UAC/lock screen). Do it silently in `run_after_install`.
3. **Registry:** migrate `HKLM/HKCU\…\RustDesk` → `…\TBFDesk` (uninstall entry, Run key, stored settings).
4. Make every step **idempotent** and safe to re-run.

**DONE 2026-10-17**, in two halves.

`Config::migrate_legacy_app_name()` (hbb_common) does the config half on **every**
platform, from `core_main()` — not from `run_after_install`, because it has to run before
the first config read, and a portable or not-yet-installed client needs it too. It copies
the old directory's files into the new one **and renames them**, which is the part the
plan above missed: `Config::file_()` spells them `{APP_NAME}.toml`, `{APP_NAME}2.toml`,
`{APP_NAME}_local.toml`, `{APP_NAME}_hwcodec.toml`, `{APP_NAME}_ab`, `{APP_NAME}_group`,
so a directory copy alone would leave `RustDesk2.toml` — the file holding the server key,
the management key and the device key — somewhere nothing reads it. It is a **copy**: the
old directory stays as the rollback path. It is a no-op once the new directory has its own
`{APP_NAME}.toml`, never overwrites a destination file, skips subdirectories (`log`,
`peers`), and reloads the in-memory config afterwards so call order cannot matter.

It covers the service account too without any privileged copying: the service process runs
`core_main()` as well, so it migrates its own profile
(`C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\…`) when it starts.

`get_legacy_cleanup()` (platform/windows.rs) does the OS half, spliced into `install_me`
before anything new is written, and into `run_after_install` for the MSI path: stop and
delete the old service, delete both uninstall registry keys (32- and 64-bit views), delete
the `.rustdesk` association and the `rustdesk` URI scheme, delete the firewall rules,
delete the shortcuts under both names, and remove the old install directory — never the
directory being installed into. Its `taskkill` carries the `PID ne` filter, because the
installer process is itself called `rustdesk.exe` and would otherwise kill itself.

What is NOT migrated, on purpose: `HKCU`-stored settings (this fork keeps none; everything
is in the config directory) and the old config directory itself, which is the rollback
copy.

### Layer 3 — packaging / bundle identifiers
- `Cargo.toml` bundle `name` → `TBFDesk`; bundle `identifier` `com.carriez.rustdesk` → `com.tbf.tbfdesk`. **macOS caveat:** changing the bundle id makes the OS treat it as a new app (breaks in-place/Sparkle upgrade) — plan a signed migration/first-install.
- Crate `name = "rustdesk"` → **optional / KEEP**. It's invisible to users, and renaming it churns hundreds of internal references + the `librustdesk`/service target names. Recommend leaving the crate name as-is; rename only user-facing packaging.

**STILL OPEN — and it is the one place where Layer 1 left an inconsistency.** On Linux the
*package* installs `rustdesk.service`, `rustdesk.desktop`, `/etc/rustdesk/xorg.conf`,
`/etc/rustdesk/startwm.sh` and `/etc/pam.d/rustdesk`, and the binary is `rustdesk` because
the crate is. Those strings used to be written as `get_app_name().to_lowercase()`, which
was right only while the app name and the package name were the same word. They now read
`platform::linux::PACKAGE_NAME`, so an installed Linux client keeps working — it does not
start hunting for a unit and a desktop entry no package ever wrote. So the state is:
**Linux config directory = `~/.config/tbfdesk` (migrated), Linux package = still
`rustdesk`.** That is deliberate and it works; Layer 3 is what makes the two agree.
No Linux package is built from this tree today (we ship the Windows exe installer), so
nothing is shipped in that mixed state.

### Layer 4 — protocol URI scheme
`rustdesk://` → `tbfdesk://` (`common.rs`). Register the new scheme; if any deep links are in use, **keep `rustdesk://` registered too** during a transition window.

**DONE 2026-10-17** — it falls out of Layer 1, since `get_uri_prefix()` is
`get_app_name().to_lowercase()`. The installer registers `tbfdesk` and **deletes** the old
`rustdesk` keys rather than keeping both: their `shell\open\command` pointed into the
install directory the same script removes, so leaving them would leave a scheme that fails
silently. Nothing in this fleet emits `rustdesk://` links. If that changes, re-register
the old scheme pointing at the new exe — four `reg add` lines in `get_after_install`.

### Layer 5 — audit `is_custom_client()` flips
Because `is_custom_client()` becomes **true** after the rename (`common.rs`), re-check every `is_custom_client`-gated branch (e.g. the "customized edition / contact your administrator" update text, `powered_by_me`) so nothing unwanted turns on.

**DONE 2026-10-17 — and the audit says it must NOT flip.** The predicate asks "did an
embedded custom-client blob override the app name?", and the only writer besides the
default is `read_custom_client()`. It was spelled `!= "RustDesk"` because that *was* the
default. Comparing against `DEFAULT_APP_NAME` keeps the original meaning and stays correct
through any future rename. Had it been left as a literal it would have become
unconditionally true and silently turned on:

- the **"powered by" link** in the left pane (`index.tis`, unless `hide-powered-by-me`);
- **five option defaults** — language, approve mode (→ `password-click`), whitelist and
  two Y/N pairs — which `index.tis` picks differently for a custom client;
- `hide_cm` in the ipc option read.

`is_rustdesk()` is the same story: its one caller is `lang::translate`, where `false`
turns on "rewrite the word RustDesk into the app name" for every translated string. This
fork's strings are already branded, and the few that still say RustDesk say it on purpose.
One of them is the **AGPL attribution**, which has no value in `en.rs` — so `translate`
falls back to the key, and the rewrite would have produced "Based on the open-source
TBFDesk project." It is now excluded by name in `lang.rs`, with a test over four locales,
so even a genuinely renamed custom build cannot rewrite the attribution.

## Rollout procedure
1. Build a TBFDesk-named client **with** the Layer-2 migration wired into first-run/after-install.
2. **Test on a machine that already has a RustDesk-named install:** confirm ID + permanent password + settings are preserved, the old service is replaced by the new one, and the new service still captures the login screen.
3. Roll out fleet-wide via the **server-driven update mechanism** (see OPEN-TODOS #1) — that lets you push + verify migration centrally. Until that exists, a one-time manual/GPO push.
4. Keep any host-side tooling (systemd unit names, packaging scripts) consistent with the new name.

## Risks & rollback
- **Failed migration = fresh empty config** → user re-registers (new ID), lost saved password. Mitigate: idempotent + verified migration; keep the old dir until the new is confirmed good.
- **macOS bundle-id change** breaks in-place upgrade — needs a signed migration/first-install.
- Treat the rename as **one-way**: once users are on `…\TBFDesk`, reverting needs the reverse migration. Test exhaustively before fleet rollout.

## Recommendation (superseded — kept for the reasoning)
Do **Layer 0 now** — it is what makes the app findable as TBFDesk and carries no migration risk. Do the full rename (Layers 1–5) as **one coordinated release, after the server-driven update feature exists** (so migration can be pushed and verified centrally). Until then, the split — **user-visible TBFDesk, internal RustDesk** — stays the correct, non-breaking state.

## What actually shipped, 2026-10-17

Layers 1, 2, 4 and 5 went out together, ahead of the server-driven update feature, because
the fleet is small enough to push an installer and the migration proved out on a machine
that genuinely had something to lose. Layer 3 is deferred and Linux packaging is pinned to
`PACKAGE_NAME` so nothing breaks while it is.

Where the names now live:

| | before | after |
|---|---|---|
| install dir | `C:\Program Files\RustDesk` | `C:\Program Files\TBFDesk` |
| exe | `rustdesk.exe` (registered as `RustDesk.exe`) | `tbfdesk.exe` |
| service | `RustDesk` / "RustDesk Service" | `TBFDesk` / "TBFDesk Service" |
| uninstall key | `…\Uninstall\RustDesk` | `…\Uninstall\TBFDesk` |
| user config | `%APPDATA%\RustDesk\config` | `%APPDATA%\TBFDesk\config` |
| service config | `…\ServiceProfiles\LocalService\…\RustDesk` | `…\TBFDesk` |
| config files | `RustDesk.toml`, `RustDesk2.toml`, … | `TBFDesk.toml`, `TBFDesk2.toml`, … |
| URI scheme | `rustdesk://` | `tbfdesk://` |
| Linux config | `~/.config/rustdesk` | `~/.config/tbfdesk` |
| Linux package | `rustdesk` | **unchanged — Layer 3** |

**Rollback.** The old config directory is still there, untouched. A RustDesk-named build
installed over the top finds it and comes up with the same ID, password and device key.
The reverse migration the "Risks" section warns about is therefore not needed — as long as
the old directory is not deleted. Do not add a step that deletes it without replacing this
paragraph.

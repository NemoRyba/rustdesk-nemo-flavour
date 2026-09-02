# TBFDesk — Session Handoff (2026-09-02)

Written for a fresh session. Read this first, then `.claude` memory `nemo-tdd-progress`.

## 0. ⭐ Self-verify the client UI with a SCREENSHOT (this unlocks the whole loop)

We wasted many rounds on an "invisible" UI element because I couldn't see the app. **I CAN** — pc2 (this Windows box) has a real desktop, so PowerShell can screen-capture the client window to a PNG and Claude can Read that PNG. **Always do this after a UI build instead of asking the user.**

```powershell
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W32 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$proc = Get-Process -Name rustdesk -EA SilentlyContinue | ? { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*TBFDesk*" } | Select -First 1
$hwnd = $proc.MainWindowHandle
[W32]::ShowWindow($hwnd, 9) | Out-Null    # SW_RESTORE
[W32]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 700
$r = New-Object W32+RECT; [W32]::GetWindowRect($hwnd, [ref]$r) | Out-Null
$w = $r.Right-$r.Left; $h = $r.Bottom-$r.Top
$bmp = New-Object System.Drawing.Bitmap $w,$h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left,$r.Top,0,0,$bmp.Size)
$bmp.Save("<scratchpad>\client_shot.png",[System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
```
Then `Read` the PNG. **Verified working** (captured a 1769×949 TBFDesk window).
- The window must be **foreground + not obscured** (CopyFromScreen grabs screen pixels). SetForegroundWindow handles it; if VS Code covers it, it still worked in testing because SetForegroundWindow raised it.
- To also drive the UI (open the ⋮ Settings dialog, hover for a tooltip) you'd need SendInput/mouse P/Invoke — NOT yet built. The main window (incl. the reload icon) captures fine without it.

## 1. ~~THE OPEN BUG~~ FIXED (2026-09-02) — reload icon by the Address book tab

**Root cause was never the SVG.** `MultipleSessions.onSize()` (ab.tis) distributes the tab-row width across ALL `#sessions-type span`s proportionally to `el.text.length`, and runs on every `view.on("size")`. The icon span has **no text** → `max-width: 0px` → squashed invisible (padding kept a clickable/tooltip hover zone — the confusing symptom). Proven via the red-box screenshot test: even a plain red div vanished; with onSize fixed, ALL prior SVG variants rendered fine.
- **Fix:** `onSize()` now `continue`s past `el.id == "nemo-refresh-ab"` in both loops (count + max-width). Icon = original `svg_reload` stroked path; theme-aware CSS in index.css: light `#666`/hover `#0071ff`, dark (`html.darktheme`) `#ddd`/hover `#4da6ff`. **Verified by screenshot in BOTH themes** (toggle `allow-darktheme` in `%APPDATA%\RustDesk\config\RustDesk2.toml`, relaunch). UNCOMMITTED — user must approve commit.
- **Screenshot capture without stealing focus:** if the user is typing, `SetForegroundWindow` loses and another window covers the shot. Use **`PrintWindow(hwnd, hdc, 2)`** (PW_RENDERFULLCONTENT) instead of CopyFromScreen — captures the window even when obscured; verified working on the Sciter window.

## 1b. DONE (2026-09-02, uncommitted) — configurable auto-update check interval

Settings → Allgemein → "Automatisch aktualisieren": ONE row — checkbox+label toggles; a PERMANENT "(value) >" trigger on the right of the same line (visible also when disabled — user insisted) opens a msgbox with a free-form number input + unit dropdown (Sekunden/Minuten). The row is split 50/50: LEFT half (checkbox+label) toggles, RIGHT half (`div.nemo-upint-right`, whole half clickable, value right-aligned) opens the dialog. ⚠️ Lesson: a separate `event click` on the inner span with `return true` did NOT stop the row-toggle handler (both fired — clicking the trigger also toggled). The working fix: ONE handler (`div.nemo-set-toggle` click) that first walks `evt.target.parent` up looking for class `nemo-upint-right` and opens the dialog/`return true` before any toggle logic. Verified by synthesized clicks (SetCursorPos+mouse_event at coords the app printed via a temp `stdout.println` of `row.box(#rect,#border,#view)` + ClientToScreen) AND by the user live. Stored in **seconds** in option `auto-update-check-interval` (empty = default 1 day; floor 10 s, cap 30 days). `updater.rs` reads it LIVE each loop pass (poll wake ≤5 min, or the interval itself if shorter) — changes apply without restart; retry backoff on busy/failure = interval clamped to [1 min, 30 min]; manual checks keep the 10-min floor. `msgbox.tis getValues()` now also collects named `<select>` values (needed for the unit dropdown; guarded, no effect on existing boxes). German strings in de.rs. Screenshot-verified (row label "90 s" edge case + dialog with preselected Sekunden; no ERROR:TIS).

## 1c. DONE (2026-09-02, uncommitted) — About dialog rebranded to TBFDesk

`MyIdMenu.showAbout()` (index.tis): RustDesk privacy/website links + Purslane copyright + slogan REMOVED. Now: Version, Fingerprint, Webseite/Support/Datenschutz as "(wird ergänzt)" placeholders, blue box "Copyright © 2026 TBF GmbH" + "Basiert auf dem Open-Source-Projekt RustDesk." (attribution kept — AGPL fork). The `.link .custom-event url='…'` click wiring is kept in place for when real URLs exist. **Low-prio TODO filed in OPEN-TODOS.md ("About-dialog placeholders")**: fill in real TBF website/support/privacy links.

## 1d. FINAL STATE — auto-update row DORMANT (user decision 2026-09-02)

- The user learned "Automatisch aktualisieren" is the SOFTWARE updater, which is inert in this fork (`do_check_software_update()` posts to the public RustDesk version server; fork is private-network-only, errors swallowed; server-driven updates = OPEN-TODOS HIGH #1). **Decision: interval clamped to 1–30 DAYS, feature turned OFF, row made NON-EDITABLE** until the TBF update server exists.
- Implementation: updater.rs filter `1..=30 days` (seconds storage, default 1 day); dialog `nemoEditUpdateInterval` now takes DAYS (1–30, no unit dropdown) but is UNREACHABLE — the row renders as `nemo-set-row fixed` WITHOUT `nemo-set-toggle`, so no click handler matches (tooltip: "Automatische Updates sind noch nicht verfügbar…"). `allow-auto-update`/`auto-update-check-interval` removed from pc2's RustDesk2.toml. To RE-ENABLE later: restore the split-row markup + right-half branch (see §1b lesson + git history of index.tis).
- Fixed noisy ERROR:TIS on every Settings open: vestigial `AudioInputs`/`Languages`/`Enhancements` native-menu components re-render UNBOUND (plain `<li>`, no methods) since the dialog rework — their `self.timer(1ms, me.toggleMenuState)` callbacks now try/catch.
- NOTE: during testing the client showed the LOGIN GATE (server-side session invalidated by the many restarts) — normal login-first behavior, config intact; user just logs in again. Gate blocks the settings dialog, so the dormant row was parse-checked but NOT screenshot-verified — verify visually after next login.

## 1e. DONE + DEPLOYED (2026-09-02) — admins get user-overridable policy

User rule: an admin logged in on a client may flip ANY setting locally (e.g. test one-way file transfer) — policy applies as defaults only. Server-side fix in `nemo_integration.rs user_policy()`: the admin branch now returns `admin_policy` with **`allow_user_override` forced true on delivery** (stored config untouched; test `admin_policy_is_delivered_user_overridable`, 42 lib tests pass). The client already honors it (`apply_policy_option`: override→DEFAULT_SETTINGS=editable, else OVERWRITE=locked). **Deployed on 176** (build-vs-DB-copy + `systemctl restart rustdesk-hbbs-nemo`, active; sessions persist). Non-admin users stay locked as before; blocked peers still get override forced false. Server checkout on 176 updated (still git-divergent); LOCAL server repo has the same change UNCOMMITTED. Verify: log in as mstep on pc2 → next policy poll → Berechtigungen rows become editable.

## 2. Also still PENDING (not started)
- **Build-version readout in the bottom-left of the left pane** so the user can verify which build is running. Needs a build id baked at compile time: `build.rs` has no git/build env today (`gen_version` only). Plan: in `build.rs` `println!("cargo:rustc-env=NEMO_BUILD_ID={}", <git short hash + date>)` + `cargo:rerun-if-changed` so it refreshes; expose via a new sciter dispatch `get_build_id()` (mirror `get_version` at `ui.rs:532`/`:825`, `ui_interface.rs:811`); show it in `index.tis` left pane.

## 3. DONE this session (all committed + pushed unless noted)
Client (GitHub NemoRyba, branch nemo-tdd, HEAD `173470f05`): encrypted direct-IP (B) + require-encrypted fail-closed (H2/H3); 1% bitrate; **Settings redesigned into a modal dialog** (sectioned, sorted by size, scroll-on-demand, dark-theme, no stray "null", account section removed, ⋮ moved into the account bar, OTP pencil removed, Password section folded in, Language/Audio/Enhancements as working in-dialog **popups**, **plain-language tooltips on every row** + German, languages restricted to DE/EN); multi-screen tiled view; address-book **reload icon by the tab** (BROKEN, see §1) + **self-filter own id**; refresh moved out of the ID field.
Server (GitHub NemoRyba, nemo-tdd, HEAD `b61e4df`… then `2a3ef79`; LIVE on 176): signed peer-key map for B; H1 (stop logging token); M3 (0600 perms); M4 (tests); **Device Policy Assignment panel** in ACL & Policy; **Connections FROM/TO show hostname+alias**. **Connection history already counts UNIQUE (source,target)** — 3× A→B = 1 entry w/ negotiations counter (no change needed).
Docs: `SPEED-AND-CODEC-RESEARCH.md`, `SECURITY-HARDENING-TODO.md` (S-A closed), `OPEN-TODOS.md`, `build-client-fast.cmd`.

## 4. Recipes
- **Client fast build:** `.\build-run-windows-client.ps1 -Fast -NoRun` (kill `rustdesk.exe` first so staging can copy). Then screenshot (§0). To keep pc2's controlled side up + refresh the controller download: copy `run-windows-client\rustdesk.exe` to `run-windows-client\rustdesk-host=85.126.226.2,key=XsN4Zx48nKhoIkVgHxPyIqtY07bHa68hW9pMIBv7Ahc=,relay=85.126.226.2,.exe` and `Start-Process` the plain exe.
- **TIScript parse check (catches black-screens):** launch with `-RedirectStandardError err.txt`, grep `ERROR:TIS`. Runs on load; dialog-only code (render) isn't exercised until the dialog opens.
- **Server deploy to 176 (no sudo):** scp the file, `diff -w` vs live to confirm only your edits, `cp` over it, `cargo build --release` with `DATABASE_URL=sqlite://./<copy>` (live db is locked), then `kill -9 $(pgrep hbbs)` (User=dev, Restart=on-failure → systemd relaunches the new binary). Verify `systemctl is-active`.
- Server key `XsN4Zx48nKhoIkVgHxPyIqtY07bHa68hW9pMIBv7Ahc=`; api token `nemo-admin-2026`; 176 checkout `~/work/rustdesk-nemo-flavour/` (git divergent — don't touch its git, only working files + binary).

## 5. User's standing instructions (this session)
- **DO NOT commit/push** until explicitly told ("i will tell you to do it"). Code is committed up to the HEADs in §3; anything after is uncommitted on disk.
- Security is priority; encryption never weakened for speed.
- After a UI build, **screenshot and verify yourself** — don't make the user report "invisible".

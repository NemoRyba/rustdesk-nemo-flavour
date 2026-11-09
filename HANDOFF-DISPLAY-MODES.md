# Handoff — multi-display modes: "windows" maximized + span cursor (Sciter AND Flutter)

**2026-11-09. For the session that implements, builds and lab-verifies this.**
Rules that apply: client `AGENTS.md` (parity rule: every change in BOTH UIs, test all four
display modes on two monitors), [LAB.md](LAB.md) (lab map, cursor-lab recipes, traps),
[FLUTTER-PORT.md](FLUTTER-PORT.md) row R3 / §5, [LAB-VIDEO-TEST-PLAN.md](LAB-VIDEO-TEST-PLAN.md)
V10b. Operator wants short messages, results only.

## 1. Operator report (2026-11-09)

1. **Mode 3 "span" (Spannen)**: the local pointer does not take the remote cursor shape
   (no resize arrows on window edges, no file-drag cursor). In "single" it works.
2. **Mode 4 "windows" (Fenster)**: all windows opened full screen. The main window could be
   resized (via its toolbar) so the local taskbar shows; the second display window stayed
   full screen, and hovering top-middle showed no menu → no way to resize it.
   **Wanted:** every window opens so the local taskbar stays visible, wherever it is
   (bottom, side, top).

## 2. State

| Repo | Branch | Head | Content |
|---|---|---|---|
| client | **`nemo-display-windows-workarea`** | `b194e9359` | from `nemo-tdd-flutter` `e31dd5889`; fix for report 2 in both UIs. **Not built.** |
| client | `nemo-tdd` | `124921284` | Sciter cursor fix for all/span/windows (2026-11-06, lab: span 29/32 → 0/32 wrong points). |
| client | `nemo-tdd-flutter` | `e31dd5889` | contains `124921284` (merge `843471068`). |
| superproject | `ccr-946cdbb1-g5j1sj` | `1e02ed6` | FLUTTER-PORT R3 + V10b steps 19-19b updated. |

### What `b194e9359` does (report 2)
- **Sciter** (`src/ui/remote.tis`, `src/ui/remote.rs`): `localMonitors()` also reads each
  monitor's work area (`view.screenBox(i, #workarea, #rectw)` → `ax/ay/aw/ah`);
  `enterDisplayWindows()` places the main window on monitor 0's work area and sets
  `View.WINDOW_MAXIMIZED` (was FULL_SCREEN); the display windows are created on their
  monitor's work area and `display_window_html` maximizes instead of full screen. Title bar
  (`SW_TITLEBAR`, resizeable) was already there.
- **Flutter**: new `tryMoveToScreenAndMaximize()` in `flutter/lib/common.dart`; a
  `maximize` flag next to `screen_rect` travels `openMonitorInNewTabOrWindow` →
  `desktop_home_page.dart` (kWindowEventOpenMonitorSession) → `openMonitorSession`
  (`utils/multi_window_manager.dart`) → `remote_tab_page.dart` (new window init and
  reused window via `setNewConnectWindowFrame`). `_enterWindows` in
  `desktop/widgets/remote_toolbar.dart` uses it for the main window and every display window.

## 3. Tasks

### T1 — Build from `nemo-display-windows-workarea`
Sciter Windows + Linux, Flutter Windows + Linux (recipes: LAB.md / HANDOFF-FLUTTER-LAB.md;
bridge codegen first for Flutter). Fix compile errors in the touched files only.

### T2 — Verify "windows" mode (report 2), both UIs, Windows + Linux controller
2 remote displays, 2 local monitors (Xvnc two heads / `rdp-multimon.sh` per LAB.md §C):
- every window maximized on its own monitor, title bar visible, **local taskbar visible**
  with the taskbar at the bottom, left, right and top (Windows); Linux with a top/side panel;
- each window — also the extra one — restore (title-bar double-click), resize, re-maximize;
  picture rescales, input maps (corners);
- closing an extra window → main falls back to "all"; switching mode → extra windows close,
  placement restored;
- Sciter `placeWindowAt` re-assert must not fight the maximize (watch for flicker / the
  window jumping back to the un-maximized frame); Linux WM may need the second
  `WINDOW_MAXIMIZED` (already sent after 150 ms).
- If Windows' maximize lands on the wrong monitor for the extra Sciter windows: create
  them with `with_pos` inside the work area (already) and maximize only after `expand`.

### T3 — Span cursor (report 1)
1. **Ask / find which build the operator used.** Sciter built before `124921284` → already
   fixed; re-run `vm/scripts/cursor-lab/multidisplay-cursor-test.sh` (and the Windows
   variant) on the current Sciter build for all four modes and attach the numbers.
2. **Flutter span is the likely remaining gap** (not covered by `124921284`, never lab-run):
   span draws through `_nemoBuildSpanRender` in `flutter/lib/desktop/pages/remote_page.dart`
   (commit `f592940e6`). Check that the span (and "all") render path is wrapped in the same
   `MouseRegion` with `_buildCustomCursor(...)` the single path uses (the `mouseRegion(...)`
   helper in `_ImagePaintState.build`), with the cursor scaled per tile
   (`NemoSpanTile` fit) — otherwise the controller shows its local arrow over the tiles.
   Same check for the Flutter "windows" display windows (separate Flutter windows:
   `CursorModel` per FFI — confirm they receive cursor data).
3. Run the cursor-lab grid for Flutter in all four modes (extend the script for the Flutter
   binary if needed: `UI=` is Sciter-specific). Target: 0 wrong points in every mode.
4. Fix in both UIs if anything is still wrong (parity rule).

### T4 — Parity + docs
- `FLUTTER-PARITY-ELEMENTS.md` / `parity` test stage: no new elements expected; run it.
- FLUTTER-PORT.md: tick R3 when T2 passes; add a row for any span-cursor fix.
- LAB-VIDEO-TEST-PLAN V10b: steps 19-19b already describe the new behaviour.

### T5 — Merge (after T2/T3 pass)
- `nemo-display-windows-workarea` → `nemo-tdd-flutter` (fast-forward / merge).
- Sciter part to the shipped branch `nemo-tdd`: `b194e9359` touches Sciter AND Flutter
  files; `nemo-tdd` has no Flutter port → apply only `src/ui/remote.tis` + `src/ui/remote.rs`
  hunks there (`git checkout b194e9359 -- src/ui/remote.tis src/ui/remote.rs` on a branch from
  `nemo-tdd`, check no other nemo-tdd-flutter-only change rides along, commit), then
  re-merge `nemo-tdd` into `nemo-tdd-flutter`. Push only with the operator's go-ahead.

## 4. Report back (short)
Per task: PASS/FAIL with the cursor-lab numbers (wrong points per mode, both UIs, both
controller OSes), what was fixed (commit ids), what remains.


## 5. Result (2026-11-09, lab)

| Task | Result |
|---|---|
| T1 build | PASS — Sciter + Flutter, Linux + Windows, from `nemo-tdd-flutter` (merge 729989bd5 + fixes) |
| T2 "windows" maximized | PASS both UIs: Linux (fake taskbar 40 px) and Windows (taskbar 752-800): every window maximized on its monitor, taskbar visible; restore/resize/re-maximize stays (no jump back); closing the extra window → "all". Fixed on the way: Flutter re-opened window not maximized (3fa3c2e9c) |
| T3 span cursor | PASS — wrong points per mode (single/all/span/windows): Linux Sciter 0/0/0/0, Linux Flutter 0/0/0/0, Windows Sciter 0/0/0/0, Windows Flutter 0/0/0/0. Report 1 = a build before 124921284 (Sciter) / the Flutter gaps fixed since (ce4c55ae5, ab888a307) |
| Extra | monitor hot-plug (operator): R19; Flutter black display: R20; keyboard + mouse: input tests 40/40 on Windows for both UIs |
| T4 docs | FLUTTER-PORT R3 ☑, R19-R21 |
| T5 merge | `nemo-display-windows-workarea` merged into `nemo-tdd-flutter`; Sciter part on `nemo-tdd` 5fccbf342; re-merged (f257c131f). **Not pushed** (operator's go) |

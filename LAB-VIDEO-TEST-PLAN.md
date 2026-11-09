# TBFDesk — Recorded GUI test plan for the VM lab (video verification)

**Status: TODO (side quest, operator request 2026-11-02). Not implemented.** Tracked as
OPEN-TODOS #52. Applies to the shipped Sciter client AND the Flutter port
(`nemo-tdd-flutter`, FLUTTER-PORT.md): every video is recorded once per build, so the two
recordings double as the parity check of FLUTTER-PORT §9.

Goal: for every GUI feature and every button, a **recorded video** the operator can watch
later and judge without running anything. Each video shows, for every step, **in text on
screen what is about to be done and what must be seen**, then the action, then the visible
result. Negative cases (wrong input, unreachable server, policy refusal) are recorded too and
must show the failure clearly, not just the absence of success.

---

## 1. Recording rules (apply to every video)

1. **One video per GUI area** (§3: V01-V15); a full run = all videos + an index page.
2. **Caption per step**, burned into the video (not a separate file only), shown for the whole
   step at the top of the frame on a solid bar:
   `V06.07  ACTION: set API server to https://does-not-exist.invalid:21120`
   `EXPECTED: sign-in fails with a connection error; status turns to "connecting"; AB empty with error`
   After the step: `RESULT: PASS` (green) / `RESULT: FAIL – <reason>` (red), held 2 s.
3. **Title card** (3 s) at the start of each video: build (version, build id, commit), OS,
   which VM, date, Sciter or Flutter.
4. **Visible proof**: every claim in EXPECTED must be visible in the frame — a dialog, a
   label, a badge colour, a file appearing in Explorer, a log line opened in an editor, a
   dashboard row in the browser. Where the proof is on another machine (the controlling peer,
   the server dashboard), the video shows a **side-by-side** (two VMs, or VM + dashboard
   browser) or cuts to it with a caption saying which machine is shown.
5. **Slow enough to read**: ≥1.5 s pause after each action; mouse pointer visible; a click
   highlight (circle) drawn on clicks.
6. **Negative steps are always followed by a restore step** (caption says so), and the
   restore is shown working.
7. **No secrets on screen**: device keys, setup strings and passwords are typed from files
   by the harness and masked in captions (`<setup string from lab2/setup-A.txt>`). The
   import dialog's field is unmasked by design — record it with a lab-only throwaway key.
8. **Naming**: `/tmp/tbf-tests/<run-id>/video/<build>/V06-settings-security.mp4`, plus
   `index.html` (one row per video: title, duration, step list with PASS/FAIL, link to the
   timestamp of each step) and `steps.json` (machine-readable).

## 2. How to record (implementation notes for the TODO)

- **Step driver**: extend `tests/gui/*` with a tiny step API —
  `step "V06.07" "<action>" "<expected>"; <do it>; check <ocr/log/api assertion>; result` —
  that writes `steps.json` with timestamps (start, action, result) and drives the caption.
- **Linux client** (Xvfb + openbox, already used by `gui-linux`): record with
  `ffmpeg -f x11grab -framerate 15 -video_size 1400x900 -i :88 …`. Click highlight via
  `xdotool` + a small overlay window, or drawn later from `steps.json` click coordinates.
- **Windows VM** (`vm/scripts/vmctl.sh`): record from the host — the VM's display via the
  hypervisor's VNC/SPICE (`ffmpeg -f … -i vnc://…` or periodic `virsh screenshot` frames
  assembled to video), so recording does not depend on software inside the guest and also
  captures UAC / the secure desktop / the lock screen.
- **Two-machine steps** (sessions): record both VMs and compose side by side
  (`ffmpeg -filter_complex hstack`), captions spanning both.
- **Dashboard proof**: headless/visible browser (`brave`, already in the prerequisites) on the
  lab dashboard, recorded as a third input when a step's proof is server-side.
- **Captions**: generate an `.ass`/`.srt` from `steps.json` and burn it with
  `ffmpeg -vf subtitles=…` (top bar, large font, PASS/FAIL colour), plus the title card.
- **Assertions** stay automated (OCR via `tests/lib/ocr.py`, log greps, lab API queries) so
  a video's PASS/FAIL is not only the viewer's impression; the video is the human-readable
  evidence of the same check.
- `tests/run-all.sh --video [--only V06]` produces the videos; `--build sciter|flutter`.

## 3. Videos and steps

Legend per step: **Action → Expected (must be visible)**. `N` = negative step.
Rows marked (F) exist only in the Flutter build so far / (S) only in Sciter; unmarked = both.

### V01 — First start and provisioning gates (fresh profile, no device key)
1. Start client on a clean profile → only the "TBFDesk / Dieses Gerät ist noch nicht eingerichtet" card + teal Import button + "Build <id>" bottom-left; no ID, no connect field, no menu.
2. Click Import → dialog with empty field, "Load from file…", helper text; no fingerprint line.
3. N: OK with empty field → dialog closes, card still shown (empty = keep, nothing imported).
4. N: paste garbage → dialog stays open with "Das ist kein gültiger Geräteschlüssel…".
5. N: Load from file → a 200 KB file → "Die Datei konnte nicht gelesen werden…".
6. N: Load from file → empty file → same message.
7. Load from file → valid `.tbfsetup` → field filled; OK → "Einstellungen importiert" summary listing "ID-Server: x (vorher y)…"; card disappears; main window with ID appears (proof: ID visible, status Ready).
8. Re-open Import (Settings) → fingerprint of the current key shown; matches the dashboard's Device keys panel (cut to dashboard).
9. Import the same setup string again → summary "already configured this way".
10. Paste a bare valid device key → accepted, no summary dialog.
11. Claim gate: server set to require claim; import a fresh key → "Warten auf Freigabe…" card; approve in dashboard (side by side) → card disappears within ~1 min on its own.
12. N: deny in dashboard → "Dieses Gerät wurde nicht freigegeben" card.
13. Service provisioning: delete key on client, push key via `--import-setup` from a console → gate disappears within 3 s without restart.

### V02 — Sign-in (sealed login) and certificate box
1. Server with `nemo-require-login` → full-window sign-in card, no Cancel, server prefilled from the setup string.
2. Certificate box: "Prüfe Serverzertifikat…" dots → orange "self-signed, allowed" with subject, issuer, SANs, SHA-256 in 8-byte groups, valid-until.
3. Untick "Unsicheres TLS erlauben" → box turns red "blocked"; N: Login → TLS error shown inline.
4. Tick again → orange; "Download certificate" → save dialog → file appears in Explorer/file manager, open it in an editor (PEM visible).
5. N: wrong password → inline error from the server, fields kept.
6. N: unknown user → inline error.
7. Proof of sealing: capture of the lab hbbs log / a packet capture view showing `/api/login` carried `sealed`, no plaintext password field (caption explains).
8. Correct login → card disappears, home with account bar "Display name" + Logout.
9. 2FA user → code dialog; N: wrong code → error; right code → in.
10. Logout → back to the required sign-in card; proof that `nemo-user-control-ticket` is gone (config file opened, key absent).
11. Optional mode (server not requiring login): "Nicht angemeldet" + Login in the account bar → dialog with Cancel; Esc closes it.
12. N: server field → bare host of a non-existent server → derived `https://host:21120` shown; cert box red "error"; Login → connection error inline.
13. Server field → bare host of the lab server with a custom ID port in config → after login the ID server keeps its port (F behaviour note).
14. Import-link on the sign-in card opens the import dialog.

### V03 — Home window
1. Account bar signed in: pill with display name (bold teal), Logout button; dark theme variant (switch theme, re-show).
2. ⋮ menu → Settings… / Open log folder / Copy recent log (tooltip shown on hover).
3. Open log folder → file manager opens the log directory (main log + `connect/` visible).
4. Copy recent log → result dialog lists files; paste into an editor → header "TBFDesk <ver> (build …) id … platform …" + redacted tail, no key/password visible.
5. N: empty log dir (lab: point log path to empty dir) → error dialog with the directory.
6. Build id label bottom-left with tooltip.
7. Status line: Ready + "Registriert" (green) with tooltip.
8. N: revoke the device key on the server → "Nicht registriert" (orange) within the poll interval.
9. N: remove the key locally → gate appears (cross-ref V01).
10. N: stop the service (Settings) → "Dienst läuft nicht" + Start service link → start → Ready again.
11. Install nag absent on a non-installed Windows client; password pencil absent; password only via Settings.
12. ID double-click → "Kopiert" toast; one-time password refresh button works (new password visible).

### V04 — Connecting and connect-time policy
1. Type an ID with a published direct endpoint → green "Direkter Zugriff möglich — host:port"; with knock policy → "⚡ Knock :62201 · eigener Schlüssel" line + tooltip.
2. Type an ID without endpoint → hint disappears.
3. Connect → session opens; toolbar badge "Direkt" (cross-ref V10).
4. N: policy `nemo-outbound-enabled=N` pushed → Connect / file transfer show "Ausgehende Verbindungen sind durch TBF-Richtlinie deaktiviert" (Sciter: buttons disabled).
5. N: `nemo-outbound-targets=<other id>` → "Ziel ist durch TBF-Richtlinie nicht erlaubt".
6. N: company-network-only on, connect to `<id>@public` → "Öffentlicher Netzwerkzugriff…".
7. N: company-network-only on with no ID server → "Firmennetz erfordert einen ID-Server".
8. N: connect to own ID → "Sie können sich nicht mit Ihrem eigenen Computer verbinden".
9. Already connected to an ID → connect again → existing session brought forward (Sciter: "Bereits verbunden" dialog).
10. N: target requires a control ticket, controller has none → session refused, message "Nicht autorisiert: <Grund>" translated in both parts.
11. Restore policy → connect works again.

### V05 — Address book
1. Signed out → AB shows sign-in tip + Login button.
2. Signed in → peers shared by the server listed; own machine not listed (caption shows own ID).
3. Reload icon next to the "Adressbuch" tab → spinner → list refreshed.
4. Dashboard: share a new computer with the user (side by side) → appears without manual reload (nemo-ab-version push, ≤ a few seconds after the next poll).
5. Search "hostname-part" → filters by hostname; placeholder "ID oder Hostname suchen".
6. Peer with endpoint → green "⚡ Direkt" chip, tooltip text; right-click → menu.
7. Menu "Direkt verbinden (ohne Relay) — host:port" → session badge "Direkt"; N: block the port on the target → session fails, no relay fallback, error shown.
8. Menu "Über Relay verbinden" → session badge "Relay".
9. Menu "Einstellungen zurücksetzen" → confirm → peer's view style/quality back to default on next connect (show before/after); N: on a peer never connected → "nothing to reset" message.
10. Empty share → "Leer" + "Der Server hat diesem Konto keine Computer freigegeben…".
11. N: sealed AB with a wrong device key (swap key) → "could not unseal the address book (device key mismatch?)", list NOT shown from cache.
12. Tag filter, rename alias, delete peer (upstream functions) still work against the TBF server (record result; note if the server refuses).
13. Tabs with German labels not truncated (Sciter: wrapping; Flutter: tooltips).

### V06 — Settings: Security & Network (incl. the "broken server" demonstrations)
1. Every row's tooltip shown once (hover sweep).
2. ID/Relay server dialog: fields, "Nur Firmennetz" checkbox; N: company-only with empty ID server → dialog stays open with error.
3. **N: API server → `https://does-not-exist.invalid:21120`** → caption lists what must break, then shows each: sign-in fails with a connection error; AB reload fails with an error; policy poll errors in the log (log opened); update banner never appears; registration badge unaffected (rendezvous still OK) — then **restore** and show each working again.
4. **N: ID server → non-existent host** → status "Verbinden…"/"Nicht bereit", own ID still shown but no registration badge; outgoing connect fails with a clear error; restore → Ready + Registriert.
5. N: relay server → non-existent → relayed session fails (direct still works if published); restore.
6. N: wrong server key → connection refused/"key mismatch" style error; restore.
7. Exe-name-locked build → dialog read-only with "Servereinstellungen sind durch den Programmnamen gesperrt" + licence; row shows "(gesperrt)".
8. Management-fixed server keys → "…durch die Verwaltungsrichtlinie gesperrt", rows greyed.
9. Management dialog: N: non-http(s) URL → error; valid → saved; enable → poll visible in server log.
10. Import setup string row opens the import dialog (cross-ref V01).
11. IP whitelist: N: invalid IP → error; valid → connections from other IPs refused (side by side).
12. Direct IP access on + port; N: port 70000 → rejected; from a peer on the LAN: direct IP connect works.
13. Proxy: set a lab proxy → traffic via proxy (proxy log); N: dead proxy → connection errors; clear.
14. WebSocket on → session still works (server log shows ws).
15. Disable UDP → hidden on public server; on lab server toggles; session still works.
16. Allow insecure TLS fallback → cross-ref V02.3.

### V07 — Settings: General, language, About
1. Alias set → shown to the controlling side/dashboard; fixed by policy → read-only + "managed by your administrator".
2. Dark theme on/off → whole UI switches.
3. Sync clipboard between sessions (local option) → cross-ref V10.12.
4. Auto update row greyed, "(1 Tag) >", tooltip "Automatische Updates sind noch nicht verfügbar"; clicking does nothing.
5. Audio input device list → select → used in a session with audio (peer hears it).
6. Enhancements: hardware codec, adaptive bitrate, remove wallpaper (peer's wallpaper disappears during session), keep awake.
7. Language: only DE (German flag), AT (Austrian flag), EN (UK flag); switch each → UI text changes immediately; unset = German.
8. About: "Über TBFDesk", version, fingerprint, build id, "Copyright © 2026 TBF GmbH", licence, **"Based on the open-source RustDesk project."** visible in every language; no rustdesk.com links.
9. Change ID (when allowed) → N: invalid ID → error; valid → new ID shown and registered.
10. Enable service toggle (Sciter row / Flutter equivalent) and RDP session sharing (Windows, installed).

### V08 — Settings: Permissions & Password (proof on the controlling peer, side by side)
For each permission: toggle off → controlling peer shows the function unavailable; toggle on → available.
1. Keyboard/mouse → peer cannot type/click (view only) / can.
2. Clipboard → copy on peer, paste on host fails / works.
3. File transfer → peer's file-transfer window refused / works.
4. Camera, terminal, remote restart, TCP tunneling, block input (Windows), LAN discovery, remote configuration modification — one pass each.
5. Approve mode: password / click / both → incoming session asks accordingly (accept dialog shown).
6. One-time / permanent / both passwords → login on peer with each type succeeds/fails accordingly.
7. Set permanent password → N: mismatching confirmation → error; set → peer logs in with it; clear → refused.
8. One-time password length 6/8/10 → visible length changes.
9. 2FA enable → QR shown; N: wrong code → refused; peer must enter TOTP.
10. Privacy mode absent everywhere (settings and session menu).

### V09 — Recording folders
1. Settings → Recording: Incoming (installed Windows) + Outgoing/Directory paths with "Öffnen" each.
2. Öffnen → Explorer opens exactly that folder (address bar visible).
3. Default on a local profile → `%USERPROFILE%\Videos\TBFDesk`.
4. Roaming profile with Videos on `\\dc\profiles$\<user>` → default `C:\ProgramData\TBFDesk\recording` (never the share); mapped drive variant too.
5. ProgramData denied by ACL → falls back to a local folder; only with no local folder the share.
6. "Ändern" → pick folder → "Öffnen" before OK → the new folder opens.
7. Delete the folder → Öffnen → created and opened.
8. Record a session (manual + auto incoming/outgoing) → file appears in the folder, plays.
9. Non-admin user → recording lands in ProgramData (write access proof).
10. Path with space/umlaut user name; policy-fixed folder → "Ändern" hidden, "Öffnen" works.

### V10 — Remote session window (two VMs side by side)
1. Toolbar badge "Direkt" (green) on a direct session, "Relay" (orange) on a relayed one.
2. Cursor shapes (OPEN-TODOS #49 list): window edges, corners, splitter, drag-and-drop with Ctrl/Alt badges and "not allowed", title-bar drag, I-beam, hand, busy, crosshair (Paint), Alt+Space→Move four-way arrows; after reconnect and display switch.
3. Display modes + picker: see the dedicated video **V10b** (every element).
6. Quality: custom slider reaches 1 %; unset quality shows "niedrig" ticked; image visibly changes.
7. Ctrl+Alt+Del and Ctrl+Alt+End → Windows secure attention screen on the target.
8. Keyboard modes, chat, file transfer, session recording button (file appears, V09).
9. Privacy mode absent from the menus.
10. Lock after session end (policy on) → close session → target shows the lock screen.
11. Dashboard "Cut" → session ends on both sides with a message; reconnect behaviour per OPEN-TODOS #29.
12. Clipboard sync between sessions: two sessions open, option on → copy in session A arrives in session B; option off → does not.
13. Audit note (end of session) → appears signed in the dashboard audit log.
14. Default view style "shrink" until chosen; choose "original" → kept for that peer on reconnect.

### V10b — Display modes and display picker, every element (dedicated video)
Setup recorded in the title card: controller with 1 / 2 / 3 local monitors (three runs),
remote host with 1, 2, 3 and 4 displays of different sizes and one portrait display. Every
step shows the controller's monitors (all of them in frame, or one capture per monitor
stacked) and the host's display arrangement.

Control (toolbar → display-mode menu)
1. Remote has 1 display → mode control and picker hidden or inert (caption: nothing to choose).
2. 2 remote displays, 1 local monitor → four entries visible: Einzeln / Alle | Spannen /
   Fenster; Spannen and Fenster **greyed**, hover → tooltip "– benötigt einen zweiten Monitor".
3. Click each greyed entry → nothing happens (no window change, no error).
4. Plug in a second local monitor (VM: add display) → re-open menu → Spannen / Fenster enabled.
5. Radio state: the current mode is ticked; exactly one tick at any time.

Mode: Einzeln (single)
6. Select → one display shown; toolbar display chips: the shown one lit.
7. Click each display chip → switches display; image matches the host's display (caption names it).
8. `\` hotkey (Sciter) / chip cycling → cycles displays in single mode only.

Mode: Alle (all, tiled in one window)
9. Select → all shown displays tiled, proportions match the host arrangement (caption shows host layout diagram).
10. Mouse over each tile → remote pointer moves on THAT display (host side shows the pointer); click a desktop icon on each display.
11. Display chip click while in Alle → returns to Einzeln on that display.
12. Resize the controller window → tiles re-layout, input still maps correctly (repeat step 10 quickly).

Mode: Spannen (span, one window over all local monitors)
13. 2 remote + 2 local → window covers both monitors; remote display 1 on the left monitor, 2 on the right, each letterboxed to fit.
14. Pointer at the four corners of each monitor → remote pointer at the four corners of the matching remote display; letterbox gap → no input (host pointer does not move).
15. Toolbar centred on the first (left) monitor.
16. Window manager moves the window → it snaps back to the span position (Windows + Linux).
17. Counts differ (3 remote, 2 local) → fallback: proportional "all" layout across the span window (caption states the rule).
18. Leave Spannen → previous window position and size restored.

Mode: Fenster (one window per remote display)
19. 2 remote + 2 local → two **maximized** windows (not full screen), one per monitor, left-to-right order matches the remote displays; each has a title bar.
19a. Local taskbar stays visible on every monitor — repeat with the taskbar at the bottom, on the left/right side and at the top (Windows), and with a top/side panel (Linux): no window covers it.
19b. Each window (also the second/extra one): double-click the title bar → restores; drag the border → resizes; maximize again → back to the work area; the picture rescales and input still maps (step 20).
20. Input in each window goes to its display (step 10 per window).
21. Close one window by hand → remaining window falls back to Alle automatically.
22. Switch to another mode → all extra windows close; original window placement restored.

Picker (≥3 remote displays)
23. Picker button shows "n/N" (e.g. 3/3); opens a list with one checkbox per display + "Alle anzeigen".
24. Untick one → "2/3", that display disappears from Alle / Spannen / Fenster immediately.
25. Untick until one is left → the last checkbox cannot be unticked (stays ticked, no change).
26. "Alle anzeigen" → back to N/N.
27. Picked subset with a gap in the middle (1 and 3 of 3) → layout as designed (Flutter: real positions with gap; Sciter: packed — caption states which build).

Persistence
28. Choose Spannen + subset 1,3 → disconnect → reconnect → after ~1 s the same mode and subset return (caption: per peer).
29. Another peer → its own saved mode (default Einzeln), not the first peer's.
30. "Reset preferences" on the peer (address book) → next connect starts in default mode with all displays.
31. Upstream setting "use all my displays for the remote session" = on → the saved TBF mode is not applied on top (caption: upstream setting wins).

Robustness
32. Host changes resolution / unplugs a display mid-session → layout updates, no crash, picker count updates.
33. Portrait remote display in Alle / Spannen → correctly rotated aspect, input mapping correct.
34. Mixed DPI controller (100 % + 150 % monitors, Windows) → span and windows place correctly; pointer mapping exact at corners.

### V11 — Update flow (lab update server with a signed manifest)
1. Manifest offers a newer version, auto policy → banner "TBFDesk <v> ist bereit…" + "Jetzt installieren".
2. Jetzt installieren → text "Angefordert…"; service installs outside sessions; client restarts at new version (About shows it).
3. Prompt window (`--nemo-update-prompt`) appears on top: title, text with version, countdown; Postpone (when allowed) → no install for 1 h (log); Now → installs.
4. Silence → countdown ends → window closes → install proceeds.
5. N: manifest with wrong SHA-256 → install refused, log line shown, client unchanged.
6. N: admin-install policy → banner says the administrator installs, no button.
7. N (Flutter): the upstream "download new version" path is refused (log line), nothing downloaded.

### V12 — Management / policy effects
1. Push a policy that fixes options → rows greyed in Settings, values match the dashboard.
2. Blocked ID → incoming session from it refused.
3. Required encrypted session → plaintext attempt refused (log).
4. Control ticket expiry → next session refused with translated "Nicht autorisiert".
5. Policy replay/rollback guard → re-sending an older policy is ignored (log).
6. Settings save (any row) after a policy update → device key and managed state unchanged (open config before/after; no key in UI-visible options).

### V13 — Tray
1. Tray icon tooltip "TBFDesk"; menu entries; "Beenden" closes the tray only, service keeps running (status from another tool).

### V14 — Installer and migration (Windows VM)
1. Installer EULA line has no rustdesk.com link.
2. Install over a RustDesk-named install → ID, password, device key preserved; old service/shortcuts gone; Start menu shows TBFDesk.
3. Silent install with `--import-setup` (cross-ref `gui-windows-provision`).
4. Uninstall → TBFDesk entries gone; rollback copy of the old config left as documented.

### V15 — Linux specifics
1. `.deb`/Arch install, desktop entry "TBFDesk", tray.
2. Wayland vs X11 session: cursor shapes, display capture, input.
3. `xdg-open` for the recording/log folders.

## 4. Done criteria
- All 15 videos recorded for the Sciter build and for the Flutter build, index page with
  PASS/FAIL per step, every FAIL linked to an OPEN-TODOS entry.
- Operator watched them and signed off per video (checkbox in the index page / this file).

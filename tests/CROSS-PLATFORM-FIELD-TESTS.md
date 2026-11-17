# Cross-platform field tests: Ubuntu 26.04 / Wayland reports (2026-11)

Field bugs from Ubuntu 26.04 users (client 1.4.21 to 1.4.23), written as **test cases** that a
tester runs the way a user would. Each case also gives the exact checks and says what (if
anything) catches the bug automatically. It is linked from [`README.md`](README.md). Keep **Status**
current, and when a case gets automated, name the stage or test.

**Why the suite missed these:** every Linux GUI stage runs on X11 (Xvfb / Xvnc + openbox;
`gui/sciter_parse.sh` even forces `GDK_BACKEND=x11`). None of them runs the per-user `--server`
that the root service starts inside a real GNOME **Wayland** session, and none uses the GNOME
screen-share portal. The Ubuntu desktop VM (see [Lab recipe](#lab-recipe)) closes that gap.

Column codes: **U-S** = Ubuntu 26.04 GNOME Wayland + Sciter · **F-L** = Flutter Linux ·
**W-S** = Windows Sciter · **W-F** = Windows Flutter · **A** = Android (Flutter mobile).
Values: *applies* (the same code path or the same behaviour) · *n/a* · *unknown* (not checked yet).
"Reported" = a user saw it there.

**Provenance:** the steps and check commands were put together on 2026-11-17 from reading the code
and **have not been run** as written. Lab results quoted as such (FT-01, FT-08, FT-09, FT-10) come
from the investigating session. Run a command once on the VM before you put it in a script.

## Overview

| ID | Title | Status | Automation |
|---|---|---|---|
| [FT-01](#ft-01) | Connect greyed, "outgoing connections disabled" on Linux | **FIXED in 1.4.23** | unit test; GUI manual |
| [FT-02](#ft-02) | Blank Sciter main window (1.4.23 dev build) | **FIXED before release** (9fcb5c2fe) | TODO guard |
| [FT-03](#ft-03) | Clock 1 h ahead: policy refused, no reason shown | **PARTLY FIXED**: message in 1.4.23; configurable tolerance unreleased | unit tests; GUI manual |
| [FT-04](#ft-04) | Copying the one-time password refreshes it | NOT YET INVESTIGATED | manual |
| [FT-05](#ft-05) | Connection-manager popup: missing on the next session, stays after the end | NOT YET INVESTIGATED | manual |
| [FT-06](#ft-06) | "couldn't capture display" on Ubuntu | LIKELY = FT-14 (session dies while GNOME's share question waits); 1.4.24 remembers the choice | manual |
| [FT-07](#ft-07) | Only one screen shared from Ubuntu | **FIXED in 1.4.24**: `is_server_running` looked for "tbfdesk --server" (binary is `rustdesk`) → fallback portal, one source, no restore token; verified 2 displays from Windows | manual |
| [FT-08](#ft-08) | Clipboard not working in either direction | NOT REPRODUCED: Windows 1.4.21 Flutter ↔ Ubuntu 1.4.23 Sciter, local Ctrl+C/V both ways and Ctrl+C/V pressed inside the session both ways all pass; awaiting logs | manual; TODO script |
| [FT-09](#ft-09) | Fullscreen: toolbar does not come down at the top middle | NOT REPRODUCED: drops down in single / all / span / window-per-display fullscreen, slow hover and flick; found instead: span did not span on native Wayland (fixed by XWayland in 1.4.24), first fullscreen click on an unfocused window swallowed, display windows keep the GTK title bar in fullscreen; need the user's monitor layout | manual |
| [FT-10](#ft-10) | Session window cannot be dragged to the other monitor | **FIXED in 1.4.24**: Sciter's caption moved the window client-side (ignored on Wayland, kept on one monitor on X11); now `gtk_window_begin_move_drag`; verified across monitors, maximized, first click after, double-click | manual; TODO script |
| [FT-11](#ft-11) | Connect fails after upgrading with the window open ("run_me No such file") | known (1.4.23 release notes), UX fix OPEN | manual |
| [FT-12](#ft-12) | Operator cannot use the TBFDesk window on the controlled machine | OPEN feature request (P4) | n/a |
| [FT-13](#ft-13) | Keyboard does not work in a session from Ubuntu (also after reconnect / restart) | **FIXED in 1.4.24**: keys go to a native Wayland window, the keyboard grab is X11; Sciter now runs under XWayland. Workaround for 1.4.23: `GDK_BACKEND=x11 rustdesk` | manual (lab: remote `xterm` → `tee /tmp/typed.txt`) |
| [FT-14](#ft-14) | Incoming session dies ("remote desktop offline" / Timeout) while GNOME's share question is open | FOUND in lab: the connection loop blocks on the portal; ~30 s unanswered → `Connection closed: Timeout` (the rendezvous link is reset too). 1.4.24 remembers the selection, so only the first session asks | manual |

---

<a id="ft-01"></a>
## FT-01 Connect greyed: "outgoing connections disabled" on Linux, Windows fine

**Reported (1.4.21 / 1.4.22):** on Ubuntu the Verbinden button stayed grey ("outgoing connections
disabled") although the admin had allowed the device. The dashboard showed the current policy as
applied, and the same user's Windows machine worked.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| applies (reported) | applies (same `ipc.rs` path; not run in the VM) | n/a (one SYSTEM config) | n/a | n/a (one process) |

**Lab:** the managed path (LAB.md, recipe B). Ubuntu VM peer `1193046` is enrolled, its policy is
editable in `/nemo/admin`, and the target `tbf2604` (`390107265`) is in the policy's targets.

**Steps (as the user):**
1. Admin: give the Ubuntu device a policy with outbound **off**.
2. User: Activities → type `tbfdesk` → open TBFDesk. Verbinden is grey and the reason is shown
   (correct under this policy).
3. User: change any setting in the window and change it back. Each save of the window sends its
   whole option map, and that is the save which stored the policy's value before 1.4.23.
4. Admin: switch the policy to outbound **on**.
5. User, without restarting anything: within a few seconds Verbinden becomes clickable. Type
   `390107265`, click Verbinden, and a password prompt appears.
6. Healing: on a machine still stuck on 1.4.22, install 1.4.23 over it without editing any files.
   Step 5 passes.

**Expected:** step 5 passes, and no policy-only key is ever stored as a plain setting.
**Status:** FIXED in 1.4.23.

**Verify (on the Ubuntu machine, as the user):**
```bash
# no stored copy of a policy-only key (the cached policy JSON in nemo-management-last-policy
# legitimately contains the name, so match the key at the start of a line only):
grep -nE "^[\"']?nemo-outbound-(enabled|targets)[\"']? *=" ~/.config/tbfdesk/TBFDesk2.toml   # expect: nothing
grep -rh 'removed a stored copy of' ~/.local/share/logs/TBFDesk/server/   # only on a healed machine, once
```

**Root cause:** on Linux the window talks to the user's `--server` over per-uid IPC, and its
`set_option` sends the **whole** options map. `Config::set_options` purged only the keys that were
in `OVERWRITE_SETTINGS` at that instant, so `nemo-outbound-enabled='N'` was stored in
`~/.config/tbfdesk/TBFDesk2.toml` and stayed after the policy changed. Windows has one SYSTEM
config, so it never happened there. **Fix (1.4.23):** `ipc.rs` strips policy-only keys
(`nemo_management_client::strip_policy_only_keys`) before `Config::set_options`, and
`scrub_stored_policy_only_keys` runs in `restore_cached_policy` / `apply_policy`. Verified in the
Ubuntu VM (Verbinden → password prompt), with Sciter.

**Automation:** `nemo_management_client::applied_policy_tests::a_window_save_never_stores_what_only_the_policy_may_set`
(stage `unit-client`). GUI: manual (**TODO**: a scripted VM check of steps 1–5).
**Parity:** the fix is in shared Rust. Flutter Linux has not been run (PARITY-GAPS **P6**). The two UIs
gate Connect differently when outbound is off (**P2**).

---

<a id="ft-02"></a>
## FT-02 Blank Sciter main window after 1.4.22 → 1.4.23 dev build

**Seen in the lab, never released:** TBFDesk opened an empty window. The log shows
`Wrong type - undefined, expected instance of function at App.render`.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| applies (dev build only) | n/a (Dart) | applies (same `index.tis`) | n/a | n/a |

**Lab:** Ubuntu VM (or any Sciter machine) with the build under test installed.
**Steps:** install the build → Activities → `tbfdesk` → the main window must show the ID, the
password and the Verbinden card.
**Status:** FIXED before release (9fcb5c2fe); no released version was affected.

**Verify:**
```bash
grep -rh 'sciter TIS' ~/.local/share/logs/TBFDesk/ | grep -i 'wrong type'          # expect: nothing
```
Windows: `Get-ChildItem "$env:APPDATA\TBFDesk" -Recurse -Filter *.log | Select-String 'Wrong type'`.

**Root cause:** TIScript does **not** hoist functions. `App.render` called `nemoPolicyProblemText()`,
which was defined about 700 lines below `class App` in `src/ui/index.tis` (introduced in 4c0d335df).
**Fixed** in 9fcb5c2fe (the function now sits above `class App`, with a comment that says why).

**Automation:** none proven yet. `sciter-parse` counts `ERROR:TIS` on the embedded page, but
nobody has checked that it reports this *runtime* error. **TODO:**
(a) a negative control in `sciter-parse` with `git show 9fcb5c2fe^:src/ui/index.tis` that must
fail with `Wrong type`; (b) a static check that every top-level function called from
`App.render` is defined above `class App`.
**Parity:** Sciter-only language trap; nothing to compare in Flutter.

---

<a id="ft-03"></a>
## FT-03 Clock / time zone: computer clock 1 h ahead

**Reported:** the user's clock was 1 h ahead (Latvia vs the server in Austria). It was a wrong clock,
not just the time zone. The policy was never applied, and the user saw no reason.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| applies (reported) | applies | applies | applies | applies (mobile connection page) |

**Lab:** managed Ubuntu VM peer. To reproduce, shift its clock:
`sudo timedatectl set-ntp false && sudo date -s '+65 minutes'`. **Undo afterwards:**
`sudo timedatectl set-ntp true`.

**Steps (as the user):**
1. With the clock 65 min ahead, open TBFDesk (Activities → `tbfdesk`) and wait for the next policy poll.
2. The connection card shows a plain sentence: "Die Richtlinie des Servers wird auf diesem
   Computer nicht übernommen: Die Uhr dieses Computers geht 65 Min. gegenüber dem Server vor. …"
   (EN: "… this computer's clock is 65 min ahead of the server …"). The minutes round up, so
   expect 65 or 66.
3. Server 1.1.19 + client 1.4.24 (both unreleased): even at the dashboard maximum (Settings →
   **Allowed clock difference (minutes)** = 60), a 65-min error stays refused and the sentence stays.
4. Tolerance check: move the clock back to +20 min (`sudo date -s '-45 minutes'`). With 5 the sentence shows 20 (or 21);
   set 30 and save, and the sentence disappears and the policy applies; set 5 again and it returns.
5. Turn automatic time back on. The sentence clears by itself on the next poll.

**Expected:** the sentence matches the real clock error, and the policy applies again as soon as
the error is within the server's tolerance.
**Status:** PARTLY FIXED. The message ships in 1.4.23; the configurable tolerance is in server
1.1.19 + client 1.4.24, both unreleased.

**Verify:**
```bash
grep -E "^nemo-policy-problem *=" ~/.config/tbfdesk/TBFDesk2.toml   # stale|65 or 66 (ahead) / future|N (behind) / gone when fine
grep -E "^nemo-clock-tolerance-secs *=" ~/.config/tbfdesk/TBFDesk2.toml   # must NOT be stored (policy-only key)
grep 'sealed credential expired' /projects/rustdesk/vm/logs/lab2-hbbs.log   # host: the server's refusals
```

**Root cause:** the server refused sealed requests outside +60 s / −300 s ("sealed credential
expired"), and the client's policy freshness window is 600 s. **1.4.23** shows the reason, computed from
the server's HTTP `Date` header (option `nemo-policy-problem`; `nemoPolicyProblemText` in Sciter,
`NemoPolicyProblem` widget in the Flutter desktop + mobile connection pages). **Server 1.1.19**
(built, not released) makes the tolerance configurable (default 5 min both ways, 1–60) and pushes it as
`nemo-clock-tolerance-secs`. Client support is in local commit 7c9db8652 (1.4.24, unreleased).

**Automation:** `unit-client`: `the_clock_is_judged_by_the_servers_date_header_with_the_servers_limits`,
`the_servers_configured_clock_tolerance_is_used_both_ways` (7c9db8652). `unit-server`:
`nemo_management::tests::the_clock_tolerance_is_symmetric_configurable_and_leaves_no_replay_gap`.
GUI: manual (**TODO**: a VM script that shifts the clock and reads the option).
**Parity:** checked in code, no gap. Both UIs use the same codes (`stale`/`future`/`rollback`/
`signature`/`failed`) and the same translation keys, and both update live: Sciter on its status
timer (`index.tis` ~2922), Flutter with a 1 s timer. Flutter has not been run in the VM.

---

<a id="ft-04"></a>
## FT-04 Copying the one-time password refreshes it

**Reported (Ubuntu user, UI not stated):** after copying the one-time password, it changed.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| reported (UI to confirm) | unknown | unknown | unknown | unknown |

**Lab:** Ubuntu VM with one-time passwords on (not the permanent lab password), no session
running; Flutter Linux bundle for the second UI; the Pixel 7a emulator for Android.

**Steps (as the user), no connection attempt in between:**
1. Open TBFDesk and note the one-time password.
2. Sciter: double-click the password field, then press Ctrl+C. Flutter desktop: double-click the
   password (a "Copied" toast appears). Android: the copy icon.
3. Open GNOME Text Editor and press Ctrl+V.
4. Wait 10 s and compare.

**Expected:** the pasted text equals the shown password, and the password does not change until a
session ends or the user clicks refresh.

**Verify:** screenshots before and after (`uvm-lab.sh shot`), plus
`grep -rh 'Temporary password rotated' ~/.local/share/logs/TBFDesk/server/` (expect nothing).
Then let the operator connect with the copied password: it must be accepted.

**Leads (code reading, unverified):** the password legitimately rotates (a) when an authorized
session ends (`server/connection.rs` ~1104), (b) after 10 consecutive wrong attempts
(`check_update_temporary_password`, which logs the line above), (c) on the refresh icon. In
Sciter that icon sits inside the same box as the read-only field (`index.tis` `PasswordEyeArea`).
(d) In Flutter, a change of `temporary-password-length` also rotates it (`server_model.dart` ~272).
Ask the user which UI, how they copied it, and whether anyone connected in between.
**Status:** NOT YET INVESTIGATED. **Automation:** manual. **Parity:** the copy action differs (Sciter has none, Flutter desktop
copies on double-click, Android has a copy icon), see PARITY-GAPS **P7**.

---

<a id="ft-05"></a>
## FT-05 Connection-manager popup: does not reappear on the next session, does not close at the end

**Reported (Ubuntu, controlled side):** the incoming-session popup did not come back for the next
connection, and it stayed open after the session ended.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| reported (UI to confirm) | unknown | unknown | unknown | unknown |

**Lab:** Ubuntu VM as the target (2 monitors, `heads2`); operator `tbf2604` or the Windows VM.

**Steps:**
1. The operator connects to `1193046`. On Ubuntu the GNOME prompt appears: switch on
   **Allow Remote Interaction** and click **Share**.
2. Watch both Ubuntu monitors for the popup (shots of head 0 and head 1).
3. The operator closes the session. The popup must close within a few seconds.
4. The operator connects again. The popup must appear again, on a visible monitor.

**Verify:** `uvm-lab.sh shot F 0` / `shot F 1` after each step; on Ubuntu run
`pgrep -a rustdesk` (which `--cm…` process exists) and `ls ~/.local/share/logs/TBFDesk/`
(which processes logged).

**Pointers (code, no mechanism claimed):** `server/connection.rs` `start_ipc` (~5459: on Linux the
`--server` starts the connection manager as `--cm-no-ui`); the `--cm-no-ui` branch in
`core_main.rs`; Sciter `cm.tis` `self.ready` (`view.move` to the top right of the work area; native
Wayland windows cannot position themselves, see FT-10). **First settle which window the user means:**
ask for a screenshot.
**Expected:** one popup per session; it appears when a session starts and closes when the session ends.
**Status:** NOT YET INVESTIGATED (suspect: a native Wayland window cannot position itself, see FT-10).
**Automation:** manual. **Parity:** not checked in either UI, PARITY-GAPS **P8**.

---

<a id="ft-06"></a>
## FT-06 "couldn't capture display" on Ubuntu

**Reported:** capture errors when someone connects to an Ubuntu machine.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| reported | applies (same `--server` capture code) | n/a (PipeWire path is Linux-only) | n/a | n/a |

**Lab:** Ubuntu VM as the target (1 and 2 monitors), operator `tbf2604`. Clear the remembered
screen choice first (see FT-07).

**Steps (try each variant, to find the trigger):** (1) the first session after login: accept the
GNOME prompt (**Allow Remote Interaction** + **Share**); (2) press **Cancel** in the prompt;
(3) a second session (the remembered choice, no prompt); (4) connect while the screen is locked
(Super+L); (5) change the monitors during a session (`heads2`); (6) connect at the GDM login
screen.

**Expected:** a picture, or a specific message the operator can act on. Never a bare capture error.

**Verify:**
```bash
grep -rhiE 'wayland|pipewire|portal|screencast|capturer|restore' ~/.local/share/logs/TBFDesk/server/ | tail -50
echo "$XDG_SESSION_TYPE"; gnome-shell --version
```
**Ask the user for:** a screenshot of the exact message (and which side showed it), when it happens
(every time / first time / after locking), the number of monitors, and the `server/` log.
**Status:** NOT YET INVESTIGATED. **Automation:** manual. **Parity:** capture is shared Rust; how each UI shows the error still has to be
compared (PARITY-GAPS **P9**).

---

<a id="ft-07"></a>
## FT-07 Only one screen shared from Ubuntu to the operator

**Reported:** an Ubuntu machine with 2 monitors shows the operator only one.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| applies | applies | n/a (no portal) | n/a | n/a |

**Lab:** Ubuntu VM with `heads2` (Settings → Displays: two monitors, joined); operator `tbf2604`.

**Steps:**
1. The operator connects. In the GNOME Remote Desktop dialog, look at what it offers: pick
   **both** monitors if it asks, switch on **Allow Remote Interaction**, click **Share**.
2. The operator opens the display menu in the toolbar: it must list 2 displays, and all / span /
   windows must work.
3. A second session: GNOME does not ask again (the remembered choice). To be asked again: Flutter →
   Settings → **Clear Wayland screen selection**. Sciter has no such button (**P1**). Lab-only
   workaround: stop every TBFDesk process, then delete the `wayland-restore-token` line from
   `~/.config/tbfdesk/TBFDesk_local.toml`.

**Verify:** `grep -c wayland-restore-token ~/.config/tbfdesk/TBFDesk_local.toml` (1 = a choice is
remembered; never print the value). Use the operator's display menu and screenshots.
**Status:** OPEN. Whether GNOME's dialog plus our portal request can share 2 monitors still has to be
checked. **Automation:** manual (the portal dialog needs clicks). **Parity:** **P1** (Sciter lacks the
reset).

---

<a id="ft-08"></a>
## FT-08 Clipboard not working in both directions (policy allows it)

**Reported:** copy & paste worked neither way, although the policy allows the clipboard.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| reported; **not reproduced** (1.4.23) | unknown (same `--server` path; not run) | unknown | unknown | unknown |

**Lab:** Ubuntu VM (`1193046`) ↔ `tbf2604` (`390107265`), a session in each direction.

**Steps (all four must pass):**
1. Ubuntu as the controller: in GNOME Text Editor, select text and press Ctrl+C. In the session,
   press Ctrl+V into a remote editor. The text arrives.
2. Ubuntu as the controller: copy on the remote side. On Ubuntu, press Ctrl+V into Text Editor.
3. Ubuntu as the controlled machine: copy in Text Editor (Ctrl+C). On the operator's machine,
   paste the text.
4. Ubuntu as the controlled machine: copy on the operator's machine. On Ubuntu, press Ctrl+V.

**Lab result 2026-11-17:** all four pass with 1.4.23 Sciter on Ubuntu 26.04 GNOME Wayland.

**Verify / triage:**
```bash
wl-paste -n; printf 'probe' | wl-copy          # Ubuntu (Wayland) clipboard, read / set
xclip -o -selection clipboard                   # X11 side (container); vm/scripts/xclipboard.py can own it
grep -rh 'XAUTHORITY=\|data control protocol' ~/.local/share/logs/TBFDesk/server/
#   XAUTHORITY=Ok("/run/user/<uid>/.mutter-Xwaylandauth.…") is required. Err(NotPresent) = no X11 fallback.
#   "Tried to initialize the wayland data control protocol clipboard, but failed" is EXPECTED on GNOME.
grep -rh 'session authorization:' ~/.local/share/logs/TBFDesk/server/ | tail -3
python3 -c 'import sys; print((int(sys.argv[1], 16) >> 4) & 3)' 0x<permissions>   # 1 = clipboard disabled, 2 = enabled
grep -HE 'disable[-_]clipboard' ~/.config/tbfdesk/peers/*.toml # operator side: per-peer toggle (stored as disable_clipboard)
```
**Mechanism:** GNOME offers no wlr / ext data-control protocol, so arboard falls back to X11 through
XWayland. That needs `DISPLAY` and `XAUTHORITY` in the user's `--server` environment (logged at
`src/server.rs` ~622). **Other things that switch the clipboard off for a whole session:** the
signed-in LDAP user's policy `enable-clipboard=N` in the server-signed control grant (merged strictly:
`server/connection.rs` `apply_control_grant`, server `control_bits_for_user`); the operator's per-peer
toolbar toggle `disable-clipboard`; the controlled machine's own "Enable clipboard" permission.
**Status:** awaiting the user's logs (the `server/` log of the controlled side, the `connect/` log
of the operator, the toolbar state). **Automation:** manual (**TODO**: a script for the four directions
with `wl-copy` / `wl-paste` in the VM and `xclip` in the container). **Parity:** both UIs have the
per-peer toggle (`header.tis`, `toolbar.dart`). Only Sciter has been run, PARITY-GAPS **P10**.

---

<a id="ft-09"></a>
## FT-09 Fullscreen: toolbar should come down at the top middle (single and multi-monitor)

**Reported:** in fullscreen, the toolbar / drop-down should come down when the mouse is at the top
middle, also in multi-monitor fullscreen.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| single PASS; multi IN TEST | unknown (other mechanism) | unknown | unknown | n/a |

**Lab:** Ubuntu VM as the controller with `heads2`. The target needs 2 displays: `tbf2604` with
2 Xvnc outputs (`vm/scripts/ubuntu-ctl/xvnc-two-heads.py`) or the host target of
`multidisplay-cursor-test.sh`.

**Steps:**
1. Connect, then click the fullscreen button in the session header.
2. Move the pointer to the top middle of each monitor and rest there 1 s: the header / toolbar
   comes down.
3. Repeat in the display modes **all**, **span** and **windows** (toolbar display menu; per-peer
   option `nemo-display-mode`). In span, also try the top middle of the whole span.
4. Leave fullscreen: the window fits its monitor again.

**Expected:** the header comes down on every monitor in every mode, and goes away again.
**Status:** single-monitor fullscreen on Ubuntu Wayland with Sciter: PASS (header appears on hover).
Multi-monitor fullscreen (all / span / windows): IN TEST (2026-11-17).

**Verify:** `uvm-lab.sh move 640 1 H; sleep 1; uvm-lab.sh shot $OUT/fs-hH.png H` for H = 0 and 1,
then look for the header with `python3 tests/lib/ocr.py find`.
**Automation:** no existing check of the reveal. `session-linux` with `FULLSCREEN=1` enters
fullscreen with the app's button (`cursor-lab/fs-click.py`), checks `_NET_WM_STATE` and runs the
cursor grid, but does not assert that the header comes down (and runs on X11 only). Manual on
X11 and Wayland (**TODO**: hover + OCR check per head). **Parity:** the mechanisms differ: Sciter reveals its auto-hidden header
from the top edge, while Flutter has a collapsible toolbar with a handle (`remote_toolbar.dart`)
that has not been run on Wayland. See PARITY-GAPS **P11**.

---

<a id="ft-10"></a>
## FT-10 Session window cannot be dragged to the other monitor (not fullscreen)

**Reported:** Ubuntu 26.04 GNOME Wayland, 2 monitors. The session window does not move when its title
bar is dragged.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| applies (**reproduced**) | unknown | n/a (Win32 moves windows) | n/a | n/a |

**Lab:** Ubuntu VM as the controller with `heads2` (2 monitors), target `tbf2604`.

**Steps (as the user):**
1. Open TBFDesk, connect to `390107265`, and keep the session in a normal window.
2. Drag the session window by its header from monitor 1 onto monitor 2.
3. Control: drag the TBFDesk **main** window the same way (standard GTK frame). It moves today.
4. Display mode **windows**: each window must land on its own monitor.

**Verify (lab):**
```bash
U=/projects/rustdesk/vm/ubuntu-vm/uvm-lab.sh; OUT=$(mktemp -d)
$U shot $OUT/before-h0.png 0                       # find the header's coordinates (ocr.py find)
$U drag <hx> <hy> 0 640 <hy> 1                     # header from head 0 to head 1
$U shot $OUT/after-h0.png 0; $U shot $OUT/after-h1.png 1   # window must be on head 1 only
# native Wayland or XWayland? 0 = native Wayland. UNTESTED: assumes x11-utils installed, Xwayland on :0
# and the session window named "rustdesk" as on X11 (LAB.md)
DISPLAY=:0 XAUTHORITY=$(ls /run/user/$(id -u)/.mutter-Xwaylandauth.* | head -1) xwininfo -root -tree | grep -c '"rustdesk"'
```
**Root cause (so far):** `src/ui/remote.html` has `window-frame="extended"`, with the header as
`role="window-caption"` (`src/ui/header.tis`). The window runs as a **native Wayland** client (no
`GDK_BACKEND` is set anywhere in the tree) and does not move. Wayland clients cannot position their
own windows, which also hits the display modes that place windows with `view.move` (`remote.tis`).
**Hypothesis under test:** run the Sciter UI under XWayland (`GDK_BACKEND=x11`). By hand: in a GNOME
Terminal run `GDK_BACKEND=x11 rustdesk` (the session windows it starts inherit the variable), then
repeat steps 2 and 4.
**Status:** REPRODUCED, fix in progress. **Automation:** manual (**TODO**: script the drag and
the per-head shot check). **Parity:** Flutter Linux drags with `windowManager.startDragging`
(`tabbar_widget.dart`) and has not been run on Wayland, PARITY-GAPS **P12**.

---

<a id="ft-11"></a>
## FT-11 Upgrading while the TBFDesk window is open: Connect fails ("run_me No such file")

**Reported:** after an upgrade, Verbinden did nothing until the user closed and reopened the window.
The 1.4.23 release notes give this workaround.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| applies (reported) | unknown | unknown | unknown | n/a |

**Lab:** Ubuntu VM with the 1.4.22 and 1.4.23 `.deb` files copied in; target `tbf2604`.

**Steps (as the user):**
1. With 1.4.22 installed, open TBFDesk (Activities → `tbfdesk`) and leave it open.
2. Install 1.4.23: double-click the `.deb` (App Center) or run `sudo apt install ./tbfdesk-1.4.23-amd64.deb`.
3. In the window that is still open, type `390107265` and click Verbinden.

**Today:** no session. **Expected after the UX fix:** the session opens, or a clear message that
TBFDesk was updated, with a one-click restart.
**Status:** known; the 1.4.23 release notes give the workaround (close and reopen the window). UX fix OPEN.

**Verify:**
```bash
grep -rh 'run_me\|Failed to spawn remote' ~/.local/share/logs/TBFDesk/
for p in $(pgrep -x rustdesk); do echo "$p $(tr '\0' ' ' </proc/$p/cmdline) -> $(readlink /proc/$p/exe)"; done
```
**Lead (code, unverified):** Sciter starts each session with `run_me` (`ui_interface.rs`
`new_remote`), which spawns `std::env::current_exe()` (`common.rs` ~801). Check whether the old
window's exe link reads `… (deleted)`.
**Automation:** manual (**TODO**: add the "window open" variant to `install-lab/ubuntu-offline-test.sh`).
**Parity:** Flutter Linux opens sessions as windows of the same process
(`desktop_multi_window`); whether it is affected has not been checked (PARITY-GAPS **P13**).

---

<a id="ft-12"></a>
## FT-12 Remote operator cannot use the TBFDesk window on the controlled machine (feature request)

**Reported:** the TBFDesk window on the controlled machine darkens when the operator points at it
and ignores remote input. The user wants a permission / policy that allows it.

| U-S | F-L | W-S | W-F | A |
|---|---|---|---|---|
| applies | unknown | applies | unknown | unknown |

**Lab:** Ubuntu VM or Windows VM as the target with the TBFDesk main window open; operator `tbf2604`.
**Steps:** the operator connects and moves the pointer onto the TBFDesk main window on the remote
desktop. Today: a dark overlay appears and clicks are ignored. **Requested:** a dedicated
permission / policy (name to be decided) that lets a trusted operator use the window. The default
stays blocked.
**Current gate:** `check_if_overlay` (`index.tis`): the server control permission
(`is_remote_modify_enabled_by_control_permissions`), otherwise the local
`allow-remote-config-modification`.
**Status:** OPEN. **Automation:** n/a until the feature exists. **Parity:** **P4** (Flutter equivalent not checked).

---

<a id="ft-13"></a>
## FT-13 Keyboard does not work in a remote session from Ubuntu 26.04

- **Reported:** "keyboard didn't work after a reconnect to the remote Windows machine"; still after restarting the client. From Windows it works.
- **Platforms:** Ubuntu 26.04 GNOME Wayland Sciter (controller) = affected (1.4.23) · Flutter Linux = not affected (checked) · Windows = not affected.
- **Root cause:** the Linux client reads the keyboard through an X11 grab (`src/keyboard.rs`, logs `[grab] Run … mode=map`); the Sciter windows ran as native Wayland windows, whose keys never reach X11. Same keys from an XWayland window arrive.
- **Steps (as a user):** connect from the Ubuntu window to a target, click into a text field of the remote, type. Disconnect, reconnect, type again.
- **Lab check:** target container `podman exec -d tbf2604 bash -c "DISPLAY=:1 xterm -e sh -c 'stty -icanon -echo; tee /tmp/typed.txt'"`, type via `uvm-lab.sh mon "sendkey …"`, then `podman exec tbf2604 cat /tmp/typed.txt`.
- **Expected:** the typed text is in the file. 1.4.23 native Wayland: empty; `GDK_BACKEND=x11`: arrives.
- **Fix:** 1.4.24 `ui.rs prefer_xwayland_for_sciter()` (GDK_BACKEND=x11 when XWayland is there; `TBFDESK_NATIVE_WAYLAND=1` opts out). Verified on the release build: first connect, reconnect, pointer out/in, and Ctrl+C / Ctrl+V arrive as `\003` / `\026` in a raw-mode remote terminal.
- **Also explains FT-08 (likely):** with dead keys, Ctrl+C / Ctrl+V pressed inside the session never reached the remote — "clipboard broken both ways".
- **Open edge case:** a session window that stayed open while the same Ubuntu machine was ALSO being controlled from Windows stopped forwarding keys (X11 focus and grab looked right); a new session window worked. Not the field scenario; to investigate.

<a id="ft-14"></a>
## FT-14 Incoming session dies while GNOME's share question is open

- **Found:** lab 2026-11-17 (Windows → Ubuntu 26.04). Probably what the field saw as "couldn't capture display" / "remote desktop offline" (FT-06).
- **Mechanism:** the server's connection loop blocks until the portal answers; the controller times out meanwhile. Server log: the portal `Start` response, then `Connection closed: Timeout` in the same second.
- **Steps:** connect from Windows to Ubuntu, wait ~30 s before clicking Share → Windows shows "Entfernter Desktop ist offline". Click Share within a few seconds → session starts.
- **Mitigation 1.4.24:** "Remember this selection" (restore token) — later sessions start without the question. Open: keep the connection alive while the question waits.

## Lab recipe

**Do not run lab steps while another session uses the VM or the containers.** Check first with
`vm/scripts/lab-status.sh`.

```bash
U=/projects/rustdesk/vm/ubuntu-vm/uvm-lab.sh; OUT=$(mktemp -d)
$U start                         # Ubuntu 26.04 desktop, GNOME Wayland, autologin user tbf
$U ssh                           # shell as tbf (key auth; never put a password on a command line)
$U heads2                        # switch on the 2nd monitor (1280x800, right of the 1st); after EVERY start
$U shot $OUT/h0.png 0            # screenshot per head (0 / 1); fails loudly if the dump fails
$U move X Y H                    # hover, in pixels of head H
$U click X Y H                   # left click
$U drag X1 Y1 H1 X2 Y2 H2        # press, move in steps, release (across heads)
$U mon 'info status'             # QEMU monitor
$U stop
python3 tests/lib/ocr.py find $OUT/h0.png "Verbinden|Connect"   # coordinates of a label
```

| Part | Where | ID / address |
|---|---|---|
| Ubuntu desktop VM | `vm/ubuntu-vm/` (`uvm-lab.sh`, `qmp-pointer.py`) | peer `1193046` |
| Controller / target container | `tbf2604` (Sciter, Xvnc `:1`; image notes `vm/scripts/ubuntu-ctl/README.md`) | peer `390107265` |
| Lab server | `vm/lab2`: hbbs/hbbr on the host (`vm/scripts/lab2-up.sh`), admin `/nemo/admin`, token in `vm/lab2/token` | containers see the host as `169.254.1.2`; the VM sees it as `10.0.2.2` and as the host LAN IP |

**Relayed container ↔ VM sessions:** use a hostname `labhost` that resolves per side. In the VM,
`/etc/hosts` has `<host LAN IP> labhost`; in the container, `169.254.1.2 labhost`. Set the VM's
option `relay-server = 'labhost:21117'` (`~/.config/tbfdesk/TBFDesk2.toml` `[options]`, with
TBFDesk stopped while you edit).

**Connecting with a password, as a user would (GNOME Terminal in the VM, so the session window is visible):**
```bash
install -m 600 /dev/null ~/pw && read -rs P && printf '%s' "$P" > ~/pw && unset P
rustdesk --connect 390107265 --password-file ~/pw
```
Otherwise start programs the way users do: Activities → type `tbfdesk` → Enter.

**Logs:**

| Platform | Where |
|---|---|
| Linux | `~/.local/share/logs/TBFDesk/<process>/rustdesk_rCURRENT.log`: `server/` (the per-user `--server`: capture, clipboard, policy poll), `connect/` (a session window), …; the main window logs into the folder itself. `grep -rh PATTERN ~/.local/share/logs/TBFDesk/` covers all of them |
| Windows | `%APPDATA%\TBFDesk`, search `*.log` recursively |
| Android | `adb shell run-as at.tbf.tbfdesk cat app_flutter/Logs/rs_rCURRENT.log` |
| Lab server | `vm/logs/lab2-hbbs.log`, `vm/logs/lab2-hbbr.log` |

**What to ask a field user for:** the version (⋮ → About), a screenshot, the `server/` and main
logs, and `grep` output for the **one** key in question. **Never ask for `TBFDesk2.toml` /
`TBFDesk.toml`**: they hold the device key and the key pair.

## Lab traps

- **The relay over `10.0.2.2` never relays.** From the VM, hbbr at `10.0.2.2:21117` accepts the
  connection and never sends the key-exchange offer, and the client says "Relay handshake failed: no key
  exchange offer from the relay". slirp makes the VM's traffic arrive from 127.0.0.1, which hbbr
  treats as its admin console (LAB.md). The `uvm-lab.sh` header says the guest reaches the host
  at `10.0.2.2`. That is true for hbbs (21116) and the API (31120), **not** for the relay. Use the
  host LAN IP / `labhost`.
- **The second monitor exists only after `heads2`.** Plain VNC never enables virtio head 1; QEMU's
  D-Bus display `SetUIInfo` does. `start` and `stop` delete `run/heads`, so run `heads2` again
  after every start.
- **Pointer coordinates span both monitors.** GNOME spreads the usb-tablet range over the whole
  2560 px desktop, and QEMU does not translate per head. `qmp-pointer.py` maps head coordinates
  using `run/heads`. If that file disagrees with what GNOME shows (for example, `heads2` failed),
  every click lands wrong. Check with a shot of head 1.
- **A stale screenshot.** `shot` used to convert an old picture when the screendump failed. This is
  fixed: it deletes the old ppm and exits non-zero. Check the exit status in scripts.
- **Native Wayland windows are invisible to X tools** (`xdotool`, `xwininfo`). Check window
  positions with per-head screenshots. `xwininfo` only tells you whether a window is XWayland.
- **The X11-only lab hides Wayland bugs.** `sciter_parse.sh` forces `GDK_BACKEND=x11`, and
  `session-linux` runs on Xvnc. A PASS there says nothing about GNOME Wayland (FT-09, FT-10).
- **GNOME remembers the screen-share choice** (restore token). Later sessions skip the dialog and
  keep the earlier monitor choice. Clear it before testing FT-06 / FT-07 (Flutter button; Sciter:
  see FT-07, **P1**).
- **One-time passwords rotate after every authorized session** and after 10 wrong attempts. Do not
  mistake that for FT-04. For repeated session tests, give the target a permanent lab password.
- **The arboard data-control warning is normal on GNOME.** It is not the clipboard bug. The bug is
  a missing `XAUTHORITY` / `DISPLAY` in the `--server`, or a policy / toggle that switches the
  clipboard off (FT-08).
- **Passwords never go on a command line or into a doc.** Use a mode-600 file and
  `--password-file`. The same applies to device keys and tokens (LAB.md).
- **GUI programs started from a plain SSH shell are not in the GNOME session.** Start them the
  way a user does (Activities, or a GNOME Terminal inside the VM).

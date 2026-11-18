# TBFDesk 1.4.25 (Linux + Windows, Sciter + Flutter) and server 1.1.19 — 2026-11-18

Client commit `4f593f3e0` (branch `nemo-tdd-flutter`), server commit `a6614ea` (branch `nemo-tdd`).
The new machine policies below need **server 1.1.19 and client 1.4.25**; everything else works with
server 1.1.18 too. Update the server first, then the clients.

## Files
| | Sciter | Flutter |
|---|---|---|
| Windows (x64) installer | `tbfdesk-1.4.25-x64-install.exe` | `tbfdesk-flutter-1.4.25-x64-install.exe` |
| Ubuntu 26.04, offline | `tbfdesk-1.4.25-ubuntu26.04-install.run` | `tbfdesk-flutter-1.4.25-ubuntu26.04-install.run` |
| Ubuntu 24.04, offline | `tbfdesk-1.4.25-ubuntu24.04-install.run` | `tbfdesk-flutter-1.4.25-ubuntu24.04-install.run` |
| Debian/Ubuntu package | `tbfdesk-1.4.25-amd64.deb` | `tbfdesk-flutter-1.4.25-amd64.deb` |
| Server | `tbfdesk-server-1.1.19-install.run` (`sudo ./… --update`), `tbfdesk-server-1.1.19-linux-x86_64.tar.gz` | |

Every file has a `.sha256`, plus `SHA256SUMS`. Installs over older versions and keeps configuration, ID and
device key. Linux: an update with the TBFDesk window open no longer breaks "Verbinden" (see below).

## New
- **"Transfer file" from inside a session**: a folder button in the session toolbar (Sciter, Flutter
  desktop); Android (next APK): ⋮ → "Zur Dateiübertragung wechseln". It opens file transfer to the same computer
  **without asking for the password again**, and is hidden where file transfer is not allowed.
- **Two machine policies** (dashboard → policy editors / global client defaults):
  - *Signed-in users need no password*: a technician signed in to TBFDesk whom the ACL allows on the
    machine connects without its password; everybody else still needs it.
  - *Disable the machine's password*: one-time and permanent passwords are refused; **only signed-in
    technicians whom the ACL allows get in**, in every approval mode — nobody who only knows the ID
    can even raise an Accept popup. Approval mode "Click" still asks the person at the machine.
  - **Turn it on for ONE machine first** and connect to it as a signed-in technician before rolling it
    out: a machine with this policy and no working sign-in path cannot be reached remotely.
- **Allowed clock difference** is set in the dashboard (Settings, default 5 min both ways); clients use it.
- **One-time password**: copy icon and double-click copy (Sciter, Flutter, Android).
- Dashboard: an editor for a machine's own policy in the device details; the reason why a direct
  connection failed is shown next to "direct-failed".

## Fixed — Ubuntu / Wayland (field reports)
- **The remote user's "Share Screen" question no longer kills the session**: the connecting side shows
  "Waiting for the remote user to allow screen sharing" and the session starts when they click Share
  (before: "remote desktop offline" after ~30 s).
- **A remembered two-monitor selection keeps both monitors** (before: the second connection showed one).
- **The connection popup on the controlled Ubuntu machine** comes back on the next connection and closes
  when the session ends, **without "TBFDesk closed unexpectedly"**.
- Full screen: one click is enough, it fills the monitor the window is on, the toolbar drops down over
  the picture, and per-display windows lose their title bar.
- **Updating while the TBFDesk window is open**: "Verbinden" starts the new program instead of nothing.

## Fixed — everywhere
- **Direct connections**: the error names the reason (no answer, refused, handshake, knock) instead of
  "see the log", and "Connect directly" tries once more with a longer budget before failing.
  Tip: dashboard → global client defaults → *Direct attempt budget* (`nemo-direct-timeout-ms`) 8000 for
  slow WAN links.
- Flutter (desktop + Android): "Verbinden" is greyed with the reason while the outgoing policy is off,
  and comes back live (as in Sciter).
- The client no longer rewrites its configuration on every policy poll (every 30 s) when nothing changed.

## Security
- A 2FA code alone no longer admits a session — the password / sign-in / Accept step must come first.
- "Switch sides" (Flutter desktop) now passes the same management checks as a normal login
  (unit-tested; not run in the lab).
- **Block / Cut now really end a running session on Linux machines with the TBFDesk window open**
  (before, the window could swallow the server's revocation).
- Server: *Block* also ends the blocked device's running sessions; the relay/punch gate enforces
  outgoing restrictions from the global, named and user policies (not only the device's own);
  the control ticket names its user from the verified sign-in only.

## Verified in the lab (Ubuntu 26.04 GNOME Wayland with two monitors, Windows 11)
Upgrade over a running window; OTP copy; waiting message + session survives a 50 s share question;
2FA: password + wrong code refused, correct code admitted; *Disable the machine's password*: a
signed-in LDAP technician gets in without a password, a not-signed-in controller is refused;
two concurrent sessions, ending one from the popup keeps the other; reconnect 3 s after a session end;
popup back on the next connection and closes cleanly; remembered selection → 2 displays; Transfer file
Ubuntu → Windows without password prompt; "disable the machine's password" refuses a not-signed-in
controller with the policy text and no popup; Flutter: outbound policy greys Connect and lifts live;
keyboard into sessions (1.4.24 fix) still works; Windows: Flutter installer over 1.4.21, toolbar
transfer button. Unit tests: server 158 + 3; client see the release commit.

## Good to know
- Linux: when the last session ends and the connection popup closes, TBFDesk restarts its background
  server (stock RustDesk behaviour, at most once a minute); the one-time password changes then.
- Ubuntu: the first "Share Screen" question must be answered within the waiting time shown; tick
  "Remember this selection" so later connections do not ask.

## Not in this release
- Android APK (unchanged, release-2026-11-12); the Android changes above ship with the next APK.
- Private (controller-only) devices and 2FA for LDAP sign-ins: planned (`PRIVATE-DEVICE-POLICY-DESIGN.md`,
  OPEN-TODOS).

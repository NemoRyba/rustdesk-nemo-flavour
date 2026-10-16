# TBFDesk — end-to-end lab verification, 2026-10-16

Everything below was run **through the GUI**, as a user would: real mouse clicks, real
typing, real `Ctrl+V` pastes off the X clipboard, real sessions. Nothing was configured by
writing a config file or calling the API, except where it says so. Screens were captured
at every step.

The lab is new and reproducible (`vm/scripts/`):

| piece | what it is | why |
|---|---|---|
| `lab2-up.sh` | hbbs + hbbr **on the host**, API on `0.0.0.0:31120` with its own self-signed cert, state in `vm/lab2/` | the relay-metrics poller reads hbbr's admin channel over loopback, which the old container lab could not do — the exact blindness OPEN-TODOS 24 is about |
| `lab2-client.sh` | the host client on its own Xvfb display, its own HOME | `fresh` wipes the HOME completely: a machine nobody has touched |
| `lab2-peer.sh` | a client inside a podman container (`LAB2_CT=` picks which) | the TBFDesk id is derived from the MAC, so two clients on one host get the SAME id; a container has its own |
| `lab2-admin.sh` + `cdp.mjs` | the dashboard in a real browser, driven over CDP | `Input.dispatchMouseEvent` is a real click at the element's centre |
| `xclipboard.py` | owns the X CLIPBOARD and serves one string | the step under test is a real paste; xclip is not installed on the dev box |
| `nemo-ldap` container | OpenLDAP over **ldaps** with a self-signed cert | the login gate is LDAP-only, and the server refuses plaintext `ldap://` |

Two notes on the harness itself, because both cost time and neither is a product bug:

- **Brave must run `--headless=new`, not as a window on a bare Xvfb.** With no window
  manager nothing composites, so `requestAnimationFrame` never fires and `ResizeObserver`
  never delivers — the dashboard sizes its panels from a ResizeObserver, so its layout
  freezes at the first measurement and buttons end up underneath the next panel. That
  looks exactly like a product bug and is not one.
- **The session runs in a child process** (`rustdesk --connect <id>`) that logs to
  `logs/RustDesk/connect/`, not the main log. Grepping the main log for "direct" finds
  nothing and proves nothing.

---

## The walkthrough

1. **Fresh install, no settings.** `lab2-client.sh fresh` / `lab2-peer.sh fresh` delete the
   client's HOME. First run shows the provisioning gate — and showed the first bug: at
   800×600 the German button label ran off the right edge of the window. Fixed (it wraps
   inside the card now) and re-shot.
2. **Operator work in the dashboard**, all by clicking: sign in with the API token,
   configure LDAP (server URL, base DN, bind DN + password, user filter), **fetch & pin the
   directory certificate**, test the login (`✓ Authenticated as marek`), add the user,
   require login, grant "All peers", generate a device key with a label.
3. **Provisioning as a user.** Open "Einrichtungszeichenfolge oder Geräteschlüssel
   importieren", **Ctrl+V** the setup string, OK. The dialog lists what it applied — ID
   server, api-server, management server, server key, management key, relay, certificate
   pin, managed policy poll, device key — and nothing refused. `RustDesk2.toml` matches.
4. **Claim and approval.** The client is refused until the operator confirms it; the claim
   appears in the dashboard ("1 client(s) waiting for your confirmation") naming the key,
   the self-reported id, how it asked and how many tries. Approve → the key binds to that
   id → the client registers.
5. **Allow, then sign in** on the client with the LDAP user. The address book populates
   with the other machine, the client's own id filtered out.
6. **Direct access.** Set "Reachable at" for a peer and give it a listening port through a
   named policy; the dashboard then shows **⇄ direct host:port** on the peer row and, in
   the peer detail, that the endpoint was **delivered** to the controller on its last poll.
   The controller's address book marks that peer with a green **⇄** badge and its menu
   gains **"Direkt verbinden (ohne Relay) — 10.89.0.3:21218"**. Clicking it:
   `TBFDesk direct: established with 10.89.0.3:21218 in 585µs, no relay`.
   Clear the endpoint and the badge, the menu entry and the listener all go away.
7. **Relay.** With no endpoint and "Immer über Relay-Server verbinden" ticked, the same
   peer connects through `169.254.1.2:21117`, and the Relayed-bytes panel shows
   **5.33 KiB · 3 kb/s · live** for it — while the earlier direct session in the same
   table reads **unused — went direct**. That is the three-state panel working: the
   verdict is only offered because the poller is known to be answering.
8. **Cut.** Cutting the live session from the Connections panel revokes it and leaves the
   peer **allowed** (`allowed_for_control: true`); the audit says "admission unchanged".

---

## What the walkthrough found that the report did not

Five defects, each fatal to the flow on its own:

1. **A device-key claim could not be approved from the dashboard at all.** `escapeAttr()`
   slugged and lower-cased everything it escaped, so the button carried
   `evudkktkksqoqp0f` for key `eVudkkTkKsqoQp0F`. Invisible because peer ids are digits.
2. **No client could sign in.** The header shape the Sciter UI sends
   (`Authorization: Bearer …`, and `""` when it has none) hit a JSON-only parser inherited
   from upstream's tcp-proxy refactor, so login and address-book calls failed before
   reaching the network. No token, no address book.
3. **A setup string never enabled the managed poll**, so a client provisioned the
   recommended way never polled: no policy, no login gate, no address book, no direct
   endpoints, no audit.
4. **`direct-access-port` could not be set in the dashboard**, and a logged-in user's
   policy replaced the device policy, so a machine's listening port vanished when someone
   signed in.
5. **The first-run gate overflowed its window** and the import dialog's label was clipped
   mid-word.

Plus one operational finding for the live server: **"no data from the relay" may simply be
an hbbr that predates the `uj` command.** The lab reproduced the symptom exactly with a
2026-09-28 hbbr binary; rebuilding it fixed it. Check the relay's build first.

## Not verified here

**Windows.** This run was Linux: the host client plus two containerised ones. The client
fixes are platform-independent (`src/`), but the Windows leg — fresh install, the Ctrl+V
paste that OPEN-TODOS 16 is about, and the service/IPC path — needs a Windows build from
this tree. The test VM has the full toolchain (VS 2022 BuildTools, Windows SDK, vcpkg with
ffmpeg/aom/libvpx/libyuv/opus for `x64-windows-static`, LLVM 15.0.6, Rust); the source is
at `C:\src` and `C:\src\winbuild.cmd` builds it with `--features inline,hwcodec`. Run it as
a scheduled task — a build started over SSH dies with the session.

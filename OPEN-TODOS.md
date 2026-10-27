# TBFDesk — Open TODOs (ranked, **each item verified against code/live state on 2026-09-02**)

**Goal:** a performance-oriented, centrally-managed, **direct** remote-control product.
**Priority order:** Security edge ▸ Management capability ▸ Performance observability ▸ Polish.
**Companion docs:** [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) (transport security detail), [HANDOFF.md](HANDOFF.md) (session state + recipes), `TODO.md` (running log), `.claude/plans/analyze-this-repository-and-fizzy-parrot.md` (full roadmap).

---

## 🔴 CRITICAL — field report 2026-10-16  *(ALL SIX FIXED; verified through the GUI in the lab)*

Found on the Windows test workstation against the live server. **All six block the
provisioning workflow or make the dashboard untrustworthy**, which is worse than a
missing feature: an operator cannot tell a working fleet from a broken one.

**Status 2026-10-16 (later the same day):** all six are fixed, and the whole flow was
re-run end to end as a user — real clicks, real pastes, real sessions — in a lab built for
it (`vm/scripts/lab2-up.sh`, `lab2-client.sh`, `lab2-peer.sh`, `lab2-admin.sh`): two
clients wiped to nothing, provisioned by pasting a setup string into the first-run dialog,
claimed and approved in the dashboard, signed in against a real LDAP, address book
populated, then one direct and one relayed session, then a cut. What each item needed is
under it. **Still unverified on Windows** — the lab run was Linux (host + two containers);
a Windows build from this tree is the remaining step.

Chasing these turned up **five more defects of the same kind**, each of which broke the
flow on its own and none of which was in the report:

- **The dashboard could not approve a device-key claim at all.** `escapeAttr()` slugged
  and lower-cased every value it escaped, so the Approve button carried
  `evudkktkksqoqp0f` for key `eVudkkTkKsqoQp0F` and the server answered "no such pending
  device-key claim". It hid because peer ids are digits, where lower-casing is a no-op.
  Fixed (escape only; `cssToken()` kept for the one CSS-class use) and pinned by a test.
- **No client could sign in, so no client had an address book.** The HTTP header string
  the Sciter UI sends (`Authorization: Bearer …`, and `""` when there is none) hit a
  JSON-only parser — inherited from upstream's tcp-proxy refactor (#14633) — so
  `/api/login-key`, `/api/login` and `/api/ab/get` failed *before* reaching the network
  with "EOF while parsing a value". Both shapes are accepted again. This is the real
  root cause behind 22.
- **A setup string never switched the managed poll on** (`nemo-management-enabled`), so a
  client provisioned the recommended way talked to nobody: no policy, no login gate, no
  address-book version, no direct endpoints, no audit — while looking perfectly
  configured. It is why 23's "provisioned, not polled" was literally true. The Windows
  exe-name bootstrap always set it, which is why only setup-string clients were affected.
- **`direct-access-port` could not be set anywhere in the dashboard**, although the peer
  panel tells the operator to set it; and a logged-in user's policy replaced the device
  policy, so the port a machine listens on vanished the moment someone signed in. Added to
  the policy editor, and injected next to `direct-server=Y` so it survives any policy.
- **The first-run gate's button overflowed the window** at 800×600 (the German label is 50
  characters) and the import dialog's label was clipped mid-word by a 30 %-wide label
  column. Both fixed; both are the first screen a new machine shows.

### 21. Setup string imports the ID server and nothing else  *(FIXED 2026-10-16, lab-verified)*
**Fixed:** `apply_setup` now READS BACK every value it writes and reports what would not
store, with the reason (`SetupOutcome::refused`) — the dialog and `--import-setup` show it
and the CLI exits non-zero, so a half-applied bundle can no longer look like a success.
The GUI writes through `ui_interface::nemo_set_provisioned_options`, one batch, past both
guards that used to drop exactly the four server keys (`is_option_fixed` and the
locked-exe `nemo_is_server_config_key`), because an import is a deliberate
re-provisioning; a `host=…,key=…` exe name is overridden explicitly
(`nemo-setup-overrides-exe-name`, honoured by `nemo_exe_custom_server_configured` and by
`bootstrap()`). The bundle also turns the managed poll on. **Verified in the lab:** a
wiped client, one Ctrl+V paste, and the dialog listed ID server, api-server, management
server, server key, management key, relay, certificate pin, managed policy poll and the
device key — with nothing refused, and all of them in `RustDesk2.toml` afterwards.

*Reported:* importing a setup string **with** a device key "still not working properly".
The only working route is import the device key, then type the server settings by hand.
After importing, the client's settings show **`custom-rendezvous-server` only** — no
`relay-server`, no `api-server`, no server `key`.

`apply_setup` (`src/nemo_setup.rs`) writes every value through `Config::set_option`, so
the **config file** should be complete — check that first, with
`tbfdesk --option api-server` and by reading `%APPDATA%\RustDesk\config\RustDesk2.toml`.
If the file is right and the UI is wrong, it is one of these two, and they are easy to
tell apart:

1. **The locked-exe guard.** `ui_interface::set_option` returns silently when
   `nemo_exe_custom_server_configured()` and the key is one of
   `NEMO_SERVER_CONFIG_KEYS` = `custom-rendezvous-server`, `relay-server`, `api-server`,
   `key`, `nemo-company-network-only` (`src/ui_interface.rs:83-107`). A client installed
   from a `rustdesk-host=…,key=…,relay=….exe` name is permanently in that state, and
   `nemo_preserve_locked_server_options` *re-writes* those four keys on every
   `set_options`. So the IPC propagation added in `3467315` drops exactly the four values
   that are missing. **This is the prime suspect**, and note the 1:1 match with what the
   user sees. If confirmed: either the setup string must be refused on a locked-exe
   client with a clear message ("this build is locked to <host> by its file name"), or
   importing one must be an explicit override of the exe name — decide which, do not let
   it half-apply.
2. **The policy poll overwrites it.** `api-server` is also a *Global client defaults*
   key pushed to every client; with `allow_user_override=false` it lands in the fixed map
   and then `is_option_fixed` makes `set_option` a no-op and `nemo_restore_fixed_options`
   re-inserts the server's value. `TOPOLOGY-DEPLOYMENT.md` already says to leave that
   field EMPTY while LAN and WAN clients differ — **check what the dashboard has in it**.

**Acceptance:** on a clean Windows client, one paste of a with-key setup string leaves
all six values set, survives a service restart and a policy poll, and the client reaches
the server with nothing typed by hand.

### 22. Address book stays empty after a setup-string import  *(FIXED 2026-10-16, lab-verified)*
**Two root causes, both found by running it:** the header parser rejected the Sciter UI's
`Authorization: Bearer …` (and `""`), so the login and address-book calls never left the
machine; and a setup string left the managed poll off, so no `nemo-ab-version` ever
arrived. Both fixed (see the block at the top). The address book is also refetched right
after an import, and an empty one now says WHY — "the server shared no computers with this
account, check the user's access rights" — instead of a bare "Empty". **Verified in the
lab:** sign-in against a real LDAP, then the book listed the other peer with its hostname,
and the client's own id filtered out.

Probably downstream of 21 (no `api-server` → no `/api/ab/get`), but confirm rather than
assume: the address book also needs a **login** (`access_token`), so check in this order —
`api-server` correct → signed in → `nemo-ab-version` arriving in the policy poll →
`getAb()` firing. If it is empty with all four right, it is its own bug.

### 23. A connected, relaying client shows "provisioned, not polled"  *(FIXED 2026-10-16, lab-verified)*
**Fixed on both sides.** The cause was real and is item 21's: a setup-string client never
polled. The label was also wrong to show as a server fault, so the Peers panel now reads
the rendezvous proof too (`device_key_proved_at`, recorded where the handshake verifies
the signature) and says **"device key — handshake only"** with what to check
(this client's api-server), or **"no management poll yet"**, instead of
"provisioned, not polled". **Verified in the lab:** a client that had proved its key but
not yet polled showed the handshake-only state; after the poll it showed "device key".

*Reported:* peer `480170882` is online, allowed, has connected over the relay, and the
Peers panel still reads *provisioned, not polled*.

That label is **literally correct**: `auth_mode` is recorded only in `client_policy`
(`record_peer_auth_mode`, `nemo_management.rs:460`), i.e. only when the client makes a
**management poll** — the rendezvous handshake does not set it. A client whose
`api-server`/`nemo-management-server` is unset never polls, so it is provisioned (a key
is bound, read from the pinned registry) and never polled. **So this is a symptom of 21,
not a separate server bug** — but it reads as a server fault, which is why it is here.
Fix the label to say what to do: *"no management poll yet — check this client's
api-server"*, and consider counting a rendezvous device-key handshake as evidence of the
key being in use (it is the same key, proved more strongly).

### 24. The Relayed-bytes panel says "went direct" for sessions that were relayed  *(FIXED 2026-10-16, lab-verified)*
**Fixed:** the poller's own state is carried into the response (`relay_poller`: enabled,
target, last success, last error) and the panel renders three states instead of two —
*relayed N bytes*, *unused — went direct* (only while the relay is known to be answering)
and *no data from the relay* (with the reason, plus a banner at the top of the panel). The
fleet counter says "not measured" rather than `0 B`, and the peer detail no longer claims
"0 — nothing relayed" when nothing is measuring. `--nemo-relay-metrics` and
`--nemo-relay-metrics-interval` are now real flags (they were env-only, while the log told
operators to pass them). **Verified in the lab:** one live relayed session showed
*5.33 KiB · 3 kb/s · live* while an earlier direct one showed *unused — went direct*, in
the same table. Also found while testing: **the live server's own "no data" may simply be
an hbbr that predates `uj`** — the lab reproduced the symptom exactly with a 2026-09-28
hbbr, and rebuilding it fixed it. Check the relay's build before digging further.

*Reported, with screenshots:* the Connections panel shows the session as **relay** via
`192.168.1.14`, the client's own window says relayed — and the Relayed bytes panel lists
five sessions, every one of them **"unused — went direct"**, with the header reading
`0 B relayed`.

The panel is wrong, and the cause is in the labelling, not the measurement:
`nemo_admin.html` renders `unused = !r.last_sample_at` → *went direct*
(`nemo_admin.html:2305`). **"No sample" means "the relay told us nothing", which is not
the same as "nothing was relayed"** — and when the metrics poller cannot reach hbbr at
all (`--nemo-relay-metrics`, loopback-only admin channel; hbbs and hbbr are in separate
containers here), *every* session gets that label. A dashboard that invents "went direct"
out of missing data is worse than one that shows nothing.

**Fix:** carry the poller's own state into the response (never-connected / last-success
timestamp) and render three distinct states — *relayed N bytes*, *unused — went direct*
(only when the poller is known-good and reported nothing for that session), and *no data
from the relay* (with the reason). Until it is known-good, the panel must say so at the
top instead of per-row verdicts. **Then** find out why `uj` is unreachable in the
container deployment.

### 25. "Cut" blocks the peer instead of just ending the session  *(FIXED 2026-10-16, lab-verified)*
**Fixed:** `cut_connection` revokes the sessions and drops the connection rows, and no
longer writes `status=0`. It returns the peer's UNCHANGED policy (so the row does not flip
to blocked), still answers 404 for an unregistered id, and the audit line says
"admission unchanged". The dashboard's confirm text, button title and column header say
what it does now. Pinned by `cutting_a_connection_revokes_sessions_and_leaves_admission_alone`.
**Verified in the lab:** cutting a live relayed session left the peer `allowed` /
`allowed_for_control: true`.

*Reported:* cutting a relayed connection leaves the peer **blocked** in Peers; the
operator then has to find it and allow it again. Not what "cut" means.

Confirmed in `cut_connection` (`nemo_management.rs`): it calls
`set_peer_policy(&pm, target, Some(0))` — a permanent admission change — *and*
`set_peer_terminate`, which is the part that actually ends the live session (the
controlled machine tears it down on its next poll; a direct session has no server-side
data path to interrupt).

**Fix:** cut = `set_peer_terminate` + drop the connection row only. Blocking stays the
separate, explicit **Block** action the Peers panel already has. If an operator wants
both, they press both — and the dashboard's confirm text must stop promising a block.

### 26. "Load from file…" in the import dialog is misaligned  *(FIXED 2026-10-16, lab-verified)*
**Fixed, and more than reported:** the row shape was wrong for this dialog twice over. The
label now sits on its own full-width row (the 30 %-wide label column clipped the German
"Einrichtungszeichenfolge oder Geräteschlüssel" mid-word) and the button lines up under
the input. **Verified in the lab** at the dialog's own width, by opening it on a wiped
client.

The button sits in its own `<div>` inside `.form .set-password`
(`src/ui/index.tis`, `open_import_device_key_dialog`), whose CSS lays out
label/input pairs; a lone button lands in the label column instead of under the field.
Give the row the same shape as the input row (an empty label cell, or a class that spans
both columns) and check it at the dialog's two widths.

---

## SECURITY

> **2026-09-27:** This file is history. The live open-items register is `../OPEN-POINTS-2026-09-21.md` (see README *Known gaps*). On 2026-09-25 three items landed: H11/H20/H22 ACL version check and H23/M13 session eviction (server `0231ccd`, completed by `897a00b` — as first committed the admin UI emptied its allowlist after a save), and H24 main-IPC authorization (client `9e18fa9e1`, reverted in `feaf523f9`: the socket was already 0600 in a 0700 dir, and the check broke root CLI commands). S-B sealing, M1, S-C, A4 and the L-items are the **2026-09-03** work below, not new.
>
> **2026-09-03:** S-B core + H4 + M1 + S-C + all L-items are **CODE-COMPLETE (uncommitted, not yet deployed to 176, not yet screenshot/live-verified).** Server suite green (48 tests); client compiles clean. Detail in [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) (2026-09-03 session). What remains open below is the transport/proto tier (M2, S-D, S-E, cert-pin enforcement), all blocked on the hbb_common fork remote (#9) and/or lockstep rollout.

### 1. S-B + H4 — trust for the management control plane  *(CORE DONE; cert-pin enforcement remains)*
*Was:* clients run with `allow-insecure-tls-fallback = 'Y'` against the self-signed cert, and the policy response delivered secrets unsealed, authed only by id+uuid.
**DONE (uncommitted):** the policy-poll response AND `/api/ab/get` are now **sealed to the provisioned device key** (sign-then-seal, NaCl sealedbox, Ed25519→Curve25519) when the client proves a pinned key — a MITM under a forged cert sees ciphertext. Client has an anti-downgrade ratchet. H4 gets an opt-in **`strip_unsealed_secrets`** mode that strips secrets from any response that can't be sealed.
**REMAINING (S-B item 5):** CA-signed/fingerprint-pinned cert with the insecure fallback OFF. The `nemo-api-cert-fingerprint` policy key is plumbed + persisted on both ends, but the rustls `PinnedVerifier` + retry-ladder short-circuit is **not built yet** (needs `libs/hbb_common/src/verifier.rs`).

### 2. M1 — device keys are a shared pool  *(DONE, uncommitted)*
Keys can now be **bound to a peer id** (`DeviceKey.peer_id`); `verify_device_signature` refuses a signature whose claimed id ≠ binding. Dashboard has a "bind to TBFDesk ID" field. Legacy unbound keys still work until re-provisioned.

### 3. M2 — blocklist trusts a self-reported id  *(OPEN — needs a proto change)*
*Verified:* the controlled side rejects blocked peers on `lr.my_id`, a field the CONNECTING client fills in. Fix = add a controller-signed `signed_id` to the `PublicKey` handshake message (proto change) and verify it against `nemo-peer-keys`. Blocked on hbb_common fork remote (#9) + lockstep rollout.

### 4. Smaller hardening (per the 2026-09-01 audit)
- **S-C** *(DONE, uncommitted)*: LDAP `tls_verify=false` now **fails closed** unless `--insecure-ldap-i-accept-mitm Y` is passed.
- **S-D** *(OPEN)*: cross-direction nonce reuse on the shared secretbox key (primitive-level, lowest severity). Needs a `tcp.rs` + proto-negotiation change (hbb_common) to avoid breaking mixed-version sessions.
- **S-E** *(OPEN)*: port-forward/RDP tunnels drop the E2E layer. Remove the two `set_raw()` calls, version-gated (hbb_common). Low practical risk here (direct desktop; tunnels likely unused).
- **L-items** *(DONE, uncommitted)*: admin API fails closed without a token (auto-generates+logs one); sealed-login nonce replay guard (ts==0 bypass removed); login user-enumeration collapsed; device-key id collision fixed; `nemo-management-allow-unsigned` compiled out of release builds.
- **S-A residue** (S-A itself ✅ closed 2026-09-02): optional TOFU store for peers absent from the pushed key map — such peers currently fail closed, which is acceptable.

---

## MANAGEMENT capability — verified open

### 5. Server-driven client updates / TBF update server  *(does not exist)*
*Verified:* the upstream updater posts to the public RustDesk version URL, which this fork blocks; no update/version/download route exists on the nemo-api. The client's "Automatisch aktualisieren" row is DORMANT (greyed, non-editable, interval clamped 1–30 days) until this exists.
**Design:** admin sets target version + download URL in the dashboard → delivered via the signed policy poll → client compares `get_version()`, downloads from the api-server (:21120), verifies an Ed25519 signature over the binary (reuse the policy-signing path) → installs (silent install needs the installed-service path).

### 6. Real force-disconnect  *(cut only blocks NEW connections)*
*Verified:* `/nemo/api/connections/cut` routes to a block-only handler; a live DIRECT session has no server data path. Needs a client-honored kill signal (designed, not built) — deliverable via the signed policy poll.

---

## PERFORMANCE / observability — verified open

### 7. Relay-vs-direct **byte** metrics  *(DONE 2026-10-16, not seen live — server `nemo-tdd`)*
*Was:* `relay_server.rs` exported no per-session byte counters, so the dashboard could only show relay NEGOTIATIONS — which say a path was offered, not that a byte went through it.
**Done:** hbbr gained `usage-json`/`uj` (the machine-readable twin of `usage`, which is unchanged); hbbs remembers `label -> (controller id, workstation id)` when it mints a relay grant and polls hbbr over its existing **loopback** admin channel, so no new authentication is involved and the live grant never leaves hbbs — the join key is `common::relay_session_label`, a hash of it. Cumulative samples are folded into deltas (fleet total counted once, both peers charged individually). Dashboard: a **Relayed bytes** panel (bytes, rate, peak, duration, live/ended/**unused — went direct**), the fleet total in the Connections header, and a per-peer row in the detail panel. Flags: `--nemo-relay-metrics <host:port>` (default `127.0.0.1:21117`, `""` or `N` disables), `--nemo-relay-metrics-interval` (default 5s).
**Open:** needs an hbbr answering `uj` on the same host to show anything — not verified against a real relayed session yet. hbbr binds its admin channel to loopback, so a relay on another host needs a tunnel (or the feature off).

### 8. `NemoSource` protobuf field  *(DONE 2026-10-16, not seen live)*
*Was:* controller identity rode smuggled in the rendezvous `version` string (`nemo-source-v1:<id>:<uuid>[:token]`) and, on the relay path, in `licence_key`.
**Done:** `NemoSource {id, uuid, token}` on `PunchHoleRequest` (field 11) and `RequestRelay` (field 10) — hbb_common `nemo-tdd` `7ad1c09` / `nemo` `a8396b5`, the same commit on both branches. New field numbers only, so an un-updated peer on either end keeps working. The server's `controller_source_any()` prefers the typed field, falls back to the marker, and logs a client that sends both and disagrees with itself; the field is threaded through all four controller gates and both recorders, and is wiped from the relay frame before it is forwarded (it carries the technician's session token, like `licence_key`). The client sends both for now.
**Still asserted, not proved** — and deliberately so: what proves a controller is the device-key handshake, which `resolve_controller_identity` keeps preferring. The field removes the ambiguity, not the need for the proof.
**Open:** a lockstep rollout is still what makes the marker removable; nothing can be deleted until every client in the field sends the field.

### 9. hbb_common fork remote  ✅ RESOLVED 2026-09-03
Forked to **github.com/NemoRyba/hbb_common** (public) + a **176 bare mirror** (`~/git/hbb_common.git`). The `nemo` branch (`40adca6` + A4 `b6aa3ca`) is pushed to both; the client `.gitmodules` now points at NemoRyba (branch `nemo`) and the gitlink is committed (`ef99cce88`, pushed to NemoRyba + 176). Fresh recursive clones now resolve. hbb_common remotes: `origin`=NemoRyba, `ubuntu`=176, `upstream`=rustdesk/hbb_common.

### 10. Rebuild the 176 Linux host binary  *(checkout is current, binary is not)*
*Verified:* client checkout on 176 reconciled to `nemo-tdd` HEAD on 2026-09-02, but `/opt/nemo-rustdesk/rustdesk` is dated 2026-08-31. Rebuild (Rust 1.75, `inline,linux-pkg-config`) and atomic-replace + `systemctl restart rustdesk-nemo.service`.

---

## NEEDS THE USER / infrastructure (not verifiable from the dev box)

### 27. The server never hears about direct sessions  *(BUILT 2026-10-19, lab-verified — live needs the hbbs deploy + clients on 1.4.11)*
Client `06a9ea753` / server `139cc6e`. The controller reports each attempt at a published
endpoint (client-audit kind `direct`: target, endpoint, established / failed /
not-tried, ms, reason). That is one POST per attempt, deduplicated per (peer, outcome)
for 10 min, sent off-thread. The controlled side adds `path` to the `new` connection audit
it already sent. The dashboard shows the session in Connections as **direct-endpoint**
(green) or **direct-failed** (red), the target's stats count both, and the Peers table's
Direct column shows them. Verified in the lab end to end, including a refused endpoint.

### 30. Direct sessions bypassed the per-user rules  *(BUILT 2026-10-19, lab-verified on Linux and Windows — live needs the hbbs deploy, 1.4.14 on every client, THEN enforcement on)*
Client `1217230c1` (1.4.14), hbb_common `f188505`, server `2608fec`. Operator report: "direct
session cannot bypass policies and control permissions". The user rules were applied only
at the rendezvous, which a direct session never passes. Now the server signs a **control
ticket** per poll (controller id + device key, LDAP user, admin, allowed machines, the
user's permission bits, epoch, 4 h validity); the controller presents it with a
device-key signature over the target and the connection's challenge; the **target**
verifies and applies it. Details and the test matrix:
[LAB-VERIFICATION-2026-10-19.md](LAB-VERIFICATION-2026-10-19.md).

**Rollout order (important):**
1. Deploy hbbs `2608fec`+ (tickets and epoch are pushed from then on; nothing is enforced).
2. Install 1.4.14 everywhere. Sessions now carry the user's permissions on every path; a
   user is refused by a machine they are not allowed to control even with enforcement off.
3. Only then set **Require management authorization for every session**
   (`nemo-require-control-ticket=Y`) in the Global defaults. From that moment a client
   older than 1.4.14 is refused by every machine.

**Found on the way, fixed before release:** on Windows the SYSTEM `--server` process polls
the policy too, without the user's token, and session processes get their config from it,
so a Windows controller would never have presented the user's ticket (with enforcement on:
every Windows technician refused). The ticket now lives in the signed-in OS user's
LocalConfig. Verified on the Win11 VM.

**Open:** the permission change that edits a user also signs that user out everywhere
(existing behaviour); a stale-ticket refusal ("out of date, try again") was not caught
live because both sides re-poll within seconds — covered by unit tests.

### 31. Lock after session end as a distributable policy  *(BUILT 2026-10-19, lab-verified)*
`nemo-lock-after-session-end=Y` (dashboard: "Lock after session end"): the target locks its
desktop when a remote-control session to it ends, closed or dropped, unless another
remote-control session to it is still open. Enforced on the target, so the technician's own
menu toggle cannot opt out. Lab: "Peer close" and "Reset by the peer" both lock. Not tested
live: the "another session still open" case.

### 32. Second click on a peer that is already open did nothing  *(DONE 2026-10-19)*
Client `8c7edcc3e`. Shows "Bereits verbunden — diese Verbindung ist bereits in einem
eigenen Fenster geöffnet", and on Windows brings that window to the front. Sessions to
other peers still open side by side (lab: two `--connect` processes).

### 33. German everywhere + language picker with flags  *(DONE 2026-10-19)*
Client `835d014f2`. Settings → Allgemein → Sprache: Deutsch (Deutschland), Deutsch
(Österreich, code `de-at`, same texts for now), English, with drawn flags. ~35 strings had
no German and ~12 bypassed translation; target refusals and the "Direkt verbinden"
failures are translated too. A unit test pins the runtime-built ones.

### 34. Server-driven client update rollout  *(BUILT 2026-10-19, lab-verified on both sides of a two-NAT setup — live needs the hbbs deploy and clients on 1.4.15; older clients cannot follow a hosted installer and need one manual install)*
Upload an installer in the dashboard → the server hosts it, signs the manifest (sha256)
and pushes `nemo-update-version`; clients with `nemo-auto-update=Y` install it outside
sessions; per-peer `client_version` in the dashboard. **Requirement (operator,
2026-10-19):** the server sits between two NATs, the company subnet and the WAN, and
clients on both sides must get the update. Design for that: the client never uses the
manifest's host, only its path, fetched from the management origin that client itself is
configured with; integrity comes from the signed sha256, not from the URL. Verified in the lab: the manifest named an address the client could not reach, and the
client updated through `10.0.2.2:31120` and, separately, through a port-translated
`192.168.2.58:41120` ([LAB-VERIFICATION-2026-10-19.md](LAB-VERIFICATION-2026-10-19.md)).
Use: Settings → Software update → choose the installer → Upload & publish; switch on
**Automatic client updates** (Global defaults, or a named device policy for a pilot group).

### 35. Update hardening: a release-signing key that is not on the server  *(TODO, operator decision 2026-10-19)*
Today the key that signs the update manifest is the server's management key. Whoever
controls the server can publish any installer, and every client with automatic updates
installs it with full system rights. Plan: a separate Ed25519 **release key** kept offline
(the operator's PC); the operator signs each installer (or its manifest) locally; clients
pin the release public key at provisioning and accept only installers signed with it. The
server then only distributes. Needs: a small signing tool for the operator, the release
public key in the setup bundle, a manifest field for the release signature, and a rotation
story. (Hardening 1, the pinned download, is done: client 020d113ed, which also fixed the
pin itself, hbb_common 69260a8.)

### 36. Update experience: a dialog on Windows, a notice everywhere, self-update on Linux  *(IN PROGRESS, operator request 2026-10-19)*
- Windows: a visible "update ready" dialog instead of a silent restart; never during a
  session (already enforced by the updater: no install while an incoming or outgoing
  session is open).
- All clients without automatic install: a German notice that a new version exists.
- Linux is part of the fleet: per-platform installers in the manifest and an installing
  updater on Linux.

### 37. TBFDesk for Android  *(TO PLAN, operator request 2026-10-19)*
Control a computer from the phone; possibly control an Android phone from a computer.

### 41. Linux client released  *(DONE 2026-10-20)*
First TBFDesk release with Linux builds: `tbfdesk-1.4.16` on NemoRyba/rustdesk-client-nemo
carries the Windows installer + a Debian/Ubuntu `.deb` (verified install+run on Debian trixie
and Ubuntu 24.04) + an Arch `.pkg.tar.zst`, each with a `.sha256`. The `.deb` is built from a
binary compiled in the ubuntu 24.04 container (an Arch-built binary is not Debian-portable);
`dist/pkg-linux.sh` assembles the packages (no dpkg-deb/rpmbuild needed). `.rpm` not yet
produced (would need an rpm build env); the server-driven update already supports linux-rpm
when one is published.

### 42. Debian/Ubuntu `.deb` client with hwcodec (H.264/H.265)  *(OPEN, operator request 2026-10-26)*
The shipped `.deb` and generic-Linux client tarball are built in the `nemo-gui` Ubuntu 24.04
container with `--features inline,linux-pkg-config` — **VP8/VP9/AV1 only, no hwcodec**, because that
container has no vcpkg static ffmpeg. The **Windows** installer (`inline,hwcodec,vram`) and the
**Arch** `.pkg.tar.zst` DO carry H.264/H.265. To close the gap: add a vcpkg `x64-linux` static
`ffmpeg` (+ the hwcodec link deps) to the Ubuntu build container, then rebuild with
`--features inline,hwcodec,linux-pkg-config` and repackage via `dist/pkg-linux.sh`, so Debian/Ubuntu
gets H.26x too. Verify with a direct session negotiating H.264/H.265 end to end. (hwcodec runtime use
still depends on a supported hardware encoder — QSV/NVENC/AMF — else it falls back to VP8/VP9/AV1.)

### 38. Flutter (Android/iOS) up to parity with the desktop client  *(IN PLAN, operator request 2026-10-19)*
The desktop client (Windows + Linux, ONE Sciter codebase, src/ui/*.tis) has all the
TBFDesk work; the mobile app is the separate Flutter tree (flutter/, ~121 dart files) and
is behind. Bring it to parity in features and UX: management poll + signed policy, Layer-1
device-key gate, sealed login, control tickets (present on connect), direct endpoints +
knock, German-first UI + language picker, the update flow (where it applies on mobile),
company-network/outbound rules, direct-session reporting. Scope per feature: some are pure
Rust (already shared via the flutter feature) and only need the Dart UI; others (Sciter-only
UI like the settings dialog) need reimplementing in Dart.

### 39. One UI everywhere: evaluate porting desktop to Flutter  *(LATER, operator interest 2026-10-19)*
Windows+Linux already share one codebase (Sciter). Moving desktop to Flutter too would give
a single UI for Windows/Linux/Android/iOS, at the cost of a large port (the whole Sciter UI
and its handlers). Decide after 38, measuring effort vs. the benefit of one UI.

### 40. Pre-production security hardening + adversarial verification  *(OPERATOR PRIORITY 2026-10-19 — before production use)*
Threat model (operator): assume users do NOT leak their logins/keys; the attack surface is
the NETWORK (internet and the company subnet) and the COMPUTERS (a machine an attacker
controls or is on the same LAN as). Verify, as a white-hat against our OWN lab, that
server<->client traffic and the trust model resist a network/endpoint attacker:
- MITM on the management API (policy poll, login, address book, update): TLS + cert pin +
  signed policy + sealed login. Confirm a tampered/stripped/replayed exchange is refused.
- The rendezvous and relay planes (device-key handshake, NemoSource, forced-relay).
- Direct sessions: the control ticket, the challenge binding, the knock (replay, spoofed
  source), the server-anchored key for direct-IP peers.
- The update path end to end (signed manifest + sha256 + pinned download; residual: the
  signing key is the server's -- see TODO 35).
- An attacker ON a client machine / same LAN: what a non-admin or a LAN peer can reach.
Method: a code-level trust-boundary review first (done where noted below), then live tests
in the lab (tcpdump/wireshark already here; ARP/DNS spoof, TLS-strip, replay; a Kali VM or
individual tools as needed). Lab only, never production. Write findings + residual risks to
a SECURITY-VERIFICATION doc.



### 29. "Cut" is undone by an immediate reconnect  *(THINK OVER — operator report 2026-10-19)*
The operator cut a live **direct** session from the dashboard's Connections panel. The
controller had the password remembered and was back in at once.

**What Cut does today** (server `cut_connection`, client `apply_session_revocation`): it
stamps "terminate sessions before T" for the target; the target ends those sessions on
its next policy poll (≤30 s). That is correct for direct sessions, which have no server
data path to interrupt. It deliberately changes nothing else (TODO 25: it no longer
blocks). A new session started after T is allowed. Two things then bring the controller
back straight away:
1. **Automatic retry.** The closed session is an ordinary "connection closed" to the
   controller, so `check_if_retry` reconnects by itself.
2. **Remembered password.** The redial logs in without asking anyone. A manual
   reconnect works the same way.

So Cut is effectively "hang up", and with a remembered password even that does not hold.

**Options to weigh**
- **A. Cut is final for that session.** The target closes with a distinct reason
  ("ended by the administrator"), which the controller treats as non-retryable, like the
  Direkt-verbinden failures (`FORCED_DIRECT_FAILED`). Stops (1), not (2). Cheap.
- **B. Cut with a cool-down.** The revocation carries "refuse new sessions from
  controller X until T+n" (n configurable, e.g. 5–15 min, or until the admin lifts it). The
  *target* enforces it, so it works for direct sessions. Stops both. The policy already
  carries the stamp; it needs the controller id(s) and an end time.
- **C. Revoke the remembered credential.** The target rotates its permanent password,
  or drops the controller from trusted devices. This hits every controller of that machine.
  Too blunt as the default, maybe an extra option.
- **D. Block** (exists) for "never again". Cut + Block is what an operator presses today.
- **Faster delivery:** the cut waits for the target's next poll (up to 30 s).
  hbbs can already push to a peer over its own rendezvous connection (H43). Pushing
  the revocation would make Cut take effect in about a second.

**Questions to decide first:** Does Cut mean "hang up" or "kick out for a while"? Per
controller, or every session on the target? Should the controller's user see why
("ended by your administrator")? How long a cool-down, and can the operator lift it
early? The new direct reports (TODO 27) already show on the dashboard whether a
controller came straight back after a cut. That evidence is useful for whatever is
chosen here.

### 28. Direct vs relay throughput on the real path  *(MEASURED 2026-10-18, one run each)*
Method: a TBFDesk TCP tunnel from the lenovo through pc2 to a Hetzner test file
(`nbg1-speed.hetzner.com`), so pc2 fetches and the lenovo↔pc2 leg is the only part that
differs. Direct vs forced relay (`352069946/r`); the operator accepted each connection
on pc2. Scripts: `vm/scripts/lenovo/speed.ps1` and `baseline.ps1`.

| path | throughput |
|---|---|
| lenovo's own download (ceiling) | 11.9 Mbit/s |
| **direct** (61.6 ms handshake) | **7.7 Mbit/s** (80.8 MB / 84 s) |
| relay | 4.6 Mbit/s (33.7 MB / 59 s) |

Direct is 67% faster; the relay costs ~40%, consistent with the ~36% measured in the lab.
Direct still reaches only 65% of the lenovo's own download, so the next limit is on pc2's
side (office uplink, or the tunnel itself). Repeat at another time of day before taking
the exact numbers as final.

### 11-0. Router A answers TCP 21666 itself — the one thing between pc2 and a direct session  *(FIXED 2026-10-18 21:54 — operator corrected the forwards; verified from outside and with the lenovo's client: established in 84 ms, no relay)*
From outside, `85.126.226.2:21666` is **reset by Router A** (TTL-proven), while ports with no
rule are dropped. So the rule exists but delivers to the router itself, not to Router B
`192.168.1.2:21666`. Router B, pc2's listener and the direct protocol were proven working.
Fix: a Port Forward on Router A to **Internal IP 192.168.1.2**, port 21666, and no input
Traffic Rule for 21666. Then re-probe from outside. Full evidence and the post-fix test:
[HANDOFF-LENOVO-PC2-DIRECT.md](HANDOFF-LENOVO-PC2-DIRECT.md).

### 11. Topology move 2026-09-04 — server VM is now `192.168.1.14` (DMZ), public `85.126.226.2`  *(IN PROGRESS)*
Design + router commands: [TOPOLOGY-DEPLOYMENT.md](TOPOLOGY-DEPLOYMENT.md). Checklist:
- [ ] Router A: static route `192.168.0.0/24 via 192.168.1.2`, DHCP reservations for `.2/.13/.14`. Router B: static WAN, wan-zone `masq=0`, ACCEPT rule `192.168.1.14 → 192.168.0.151 tcp/636` (LDAPS — without it every login fails).
- [ ] VM: `sudo -E bash scripts/vm-apply-server-address.sh` (hbbs `-r 85.126.226.2:21117 --local-ip 192.168.1.14`, dev+gdm client configs → `192.168.1.14`, restart, reachability check).
- [x] pc2 `RustDesk2.toml` → `192.168.1.14` (done 2026-09-04; backup kept). Then log in on the client and screenshot-verify the new *Sync clipboard between sessions* row.
- [ ] Dashboard → Global client defaults: keep `api-server` EMPTY until a DNS name exists (one value can't serve LAN + internet clients).
- [ ] Router A port forwards → `192.168.1.14`: TCP 21115/21116/21117 + UDP 21116 now; **21120 only after** the cert pin (#1) is enforced and `allow-insecure-tls-fallback` is off fleet-wide, or reach it via WireGuard. Never forward to a workstation.
- [ ] DNS name (split horizon: `192.168.1.14` inside via the DC, `85.126.226.2` outside) → then use it in `-r`, all client configs, the locked-exe names, and the cert.
- [ ] Optional server feature before 21120 goes public: source allowlist for `/nemo/*` (admin API + dashboard) so only LAN/VPN reaches it while `/api/*` stays open to clients.
- Whereabouts of the second VM (was `192.168.0.179`) after the move: unknown — decide whether it comes back as `192.168.1.x`.

### 11b. WAN/NAT path measurement + per-workstation codec tuning
Needs the real topology (now in place, see 11) and a person at both ends (e2e/ harness is ready). Related: both OpenWrt 19.07.1 routers are EOL — upgrade (S10) before exposing the DMZ to the internet.

### 11c. Router: upgrade firmware, then run `fwknopd` at the edge  *(DEFERRED 2026-10-06 — needs a firmware flash)*
**Lab result 2026-10-19 ([OPENWRT-FWKNOP-LAB.md](OPENWRT-FWKNOP-LAB.md)):** on a virtual OpenWrt
19.07.1 (same package arch, kernel and LuCI as the WDR4300), `opkg install fwknopd` from the
official feeds works and gates the forward end to end with the TBFDesk client's own knock
(DNAT per knocking source, 30 s window, replay and wrong keys refused, session survives the
window). So a **stock** 19.07.1 needs no flash; the production error points at a non-stock
image or a missing iptables entry in opkg's database: run the diagnostics in that doc
first.

**Multiple workstations per router — DONE 2026-10-25.** The old "one workstation per key
pair" limit is lifted. Two layouts, both lab-validated at the SPA layer in an isolated
`fwknopd` 2.6.11 (key→stanza match, per-key HMAC rejection, per-port `OPEN_PORTS` scoping,
and our real client encoder accepted only by its own stanza):
- **Option A** — one site key, port-preserving, one stanza whose `OPEN_PORTS` lists every
  external port. No client change (the client already knocks the per-endpoint external
  port). No per-workstation isolation.
- **Option B** — one key + stanza per workstation, per-port isolation. New: client reads a
  per-peer `nemo-knock-keys` map and `knock_config_for(peer_id)` picks the peer's key
  (`src/nemo_direct.rs`, tests `knock_keys_parse_per_peer`,
  `a_peer_absent_from_the_knock_key_map_has_no_key`); server assembles the map per
  controller filtered by the outbound-targets ACL and distributes it in the sealed policy
  (`nemo_management.rs` `knock_key_map`, API `POST /nemo/api/peers/:id/knock-key`, tests
  `knock_key_map_is_filtered_like_endpoints`, `knock_key_normalisation_refuses_what_would_forge_rows`).
  A peer with no row falls back to the fleet-wide key, so A and B coexist.

See [ROUTER-KNOCK-RUNBOOK.md](ROUTER-KNOCK-RUNBOOK.md) §11 for both recipes.
Still open on the server side: a dashboard **field** to type the per-peer key pair (the
API and storage exist; the HTML input is not wired yet).
*Verified 2026-10-06:* installing `fwknopd 2.6.10-3` on the **external** router (LuCI → Software) fails with
`Required dependency package kernel is not available in any repository`. The package pulls
`iptables` → `kmod-ipt-core` → `kernel`, and every OpenWrt `kmod-*` is pinned to the exact kernel of
the build the router is running. Nothing in the repo matches, so **no kernel module can be installed
on that router at all** — not just this one. Expected on an EOL 19.07.1 whose kmod feed is gone or
re-spun. (The dialog also showed `iptables` itself as NOT INSTALLED, which would be unusual on
19.07/fw3 — so confirm the actual release before choosing a path.)

Diagnose first: `cat /etc/openwrt_release; uname -r; opkg print-architecture; which iptables nft fw3 fw4`.

Paths, in order of preference:
1. **Upgrade both routers to a supported OpenWrt release**, then install `fwknopd` from a live feed.
   This is the real fix and S10 already requires it before the DMZ faces the internet. An EOL router
   is a poor place to *add* a security control.
2. If the router turns out to be 22.03+ with **fw4/nftables**: try `iptables-nft` instead of legacy
   `iptables`. It provides the iptables CLI over nftables with **no legacy kmods**, which may satisfy
   `fwknopd`'s dependency without touching the kernel at all.
3. **ImageBuilder** a firmware with `fwknopd` and deps baked in. Reliable and reproducible for both
   routers — but it is a flash either way, so (1) is better.
4. **Move the gate off the router:** run `fwknopd` on the server VM (default-DROP, opened per source
   by a valid SPA) with the router forwarding blindly. Protects the *server* ports (21120 admin,
   21116/21117) and needs no router packages. Does **not** cover per-workstation direct ports — the
   gate must live where the traffic lands, and fwknop on Windows is Cygwin-based and not deployable.

**Until a router can gate:** per-workstation direct forwards are protected by **source-IP allowlists**
on the router (no packages, works on 19.07 as-is) — adequate while technician IPs are static, and the
only option left if they roam. Do (4) for 21120 regardless, since it is the admin surface.

**None of this blocks the client work:** the knock is implemented and the SPA packets are byte-for-byte
fwknop-compatible (`rustdesk-client-nemo/src/nemo_direct.rs`, contract test
`spa_encoder_reproduces_the_real_fwknop_packet`), so it does not care whether `fwknopd` ends up on the
router, the server VM, or a replacement edge box. Only `nemo-knock-port` changes.

---

## PROVISIONING UX + Windows branding — reported 2026-10-16 from the Windows test workstation
*(16 is a rollout blocker and is placed here by priority; the numbers continue at 16 so existing references to 12–15 stay valid. Code refs below re-checked against the tree on 2026-10-16.)*

### 20. Client setup string  *(DONE 2026-10-16, not seen live)*
A fresh client needed **six** exact server values typed in before it could reach the server at all — ID/rendezvous server, relay, api-server URL, management URL, the server's identity key, its certificate fingerprint — plus the device key. One wrong character fails as "cannot reach the server".
**Done:** the dashboard hands them over as `tbfdesk-setup-v1:<base64 json>`, **twice** — an `internal` (LAN) and an `external` (public) profile, since the server has two addresses and a client carries one set; the public one is derived from `-r` and never from the dashboard address, and says so rather than guessing when the server has none. *Settings → Device keys* has the editable fields (prefilled from the dashboard's own Host header) with **Copy string** / **Download file**; generating a device key returns the same bundle **with that key inside it**. The client's *Import device key* dialog takes either a bare key or a setup string, plus **Load from file…**; `tbfdesk --import-setup <file|string>` does it unattended. Server `/nemo/api/client-setup` (GET defaults, POST edits), overrides `--nemo-client-id-server` / `--nemo-client-relay` / `--nemo-client-api`.
**Open:** not exercised against a real client yet (no Windows/Sciter build here). The bundle is the client's trust anchor and is deliberately unsigned — what a signature would be checked against is the key inside it — so it must be handed over like a password.
**Side effect worth knowing:** *Load from file…* is also a working paste-free route into that dialog, which is most of what **16** below is about.

### 16. "Geräteschlüssel importieren" dialog: **Ctrl+V does nothing**  *(blocks provisioning — partly worked around by 20)*
**2026-10-16:** the setup-string work (20) added a **Load from file…** button to this dialog, which is candidate fix #1 from the list below and sidesteps the clipboard entirely: the operator downloads the `.tbfsetup` from the dashboard and picks it. Ctrl+V itself is still unfixed, and the diagnostic below is still the way to find out which layer eats it.
Reported on the installed Windows client. This dialog is the **only** way a device key reaches a client (`rustdesk-client-nemo/src/ui/index.tis:601` `open_import_device_key_dialog`), the key is a 44-char base64 secret nobody will retype correctly, and Layer 1 makes it mandatory — so broken paste is a rollout blocker, not a cosmetic bug.

**Already ruled out** (static read, no VM needed): no TIS handler eats the keystroke. The two in scope — `msgbox.tis:303` and `index.tis:2365` — both guard on `if (!evt.shortcutKey)`, so they skip every Ctrl-combination, and neither returns `true`; the third (`common.tis:219`) is scoped to the chatbox behavior and never sees this dialog.

**Constraint on any fix:** the field is `<input|password name='devkey'>` (`index.tis:608`) and the masking is deliberate — `index.tis:602-604` records why: with the key rendered, a remote operator watching the screen could copy this machine's Layer 1 identity straight out of the input. A fix must keep that property.

**First diagnostic (≈2 min on the workstation, no rebuild)** — try Ctrl+V in each of:
1. the **permanent-password** dialog — also `input|password` (`index.tis:1279`),
2. the **IP-whitelist** dialog — a plain `<textarea>` (`index.tis:645`),
3. the **ID field** on the main window.

All three fail → host/Sciter clipboard integration. Only the two password fields fail → Sciter's masked edit refuses paste. Only this dialog fails → something specific to it. Also try **Shift+Insert** and right-click in the field; whichever works is the interim line to add to the provisioning instructions.

**Candidate fixes, best first:**
- **An "Einfügen" button beside the field** that reads the clipboard on the Rust side and sets the value. Sidesteps Sciter's edit behavior entirely, keeps the masking, and works whichever layer turns out to be at fault. Needs no new dependency: `arboard` is already in `Cargo.toml:109` and the UI↔Rust bridge exists (`src/ui/inline.rs`).
- A **"Schlüssel anzeigen"** toggle that switches the field to `input|text` while held — cheap, but erodes the on-screen-secret property above; worth it only *alongside* the button, not instead of it.
- Chasing it inside Sciter's own `behavior:edit` — last resort, we do not control that code.

**Acceptance:** a key can be entered by Ctrl+V *and* by the button; a bad paste still keeps the dialog open with the existing error (`index.tis:618-624`); the key is still never rendered in plaintext.

### 16b. "creating Geräteschlüssel at …" — **report truncated, needs one detail**
The 2026-10-16 message breaks off mid-sentence, so the ask is unknown. For the record, the flow it points at: keys are minted in the dashboard's **Device keys** panel (`rustdesk-server-nemo/src/nemo_admin.html:931`, button `#generateDeviceKey` → `POST /nemo/api/device-keys`), the private half is **shown once** and must be copied immediately, then pasted into the client via 16's dialog. Open question for the user: is this (a) a second bug on that panel, (b) the same copy/paste problem at the *server* end, or (c) a request to document where keys are created?

### 19. Device-key first-use binding with operator confirmation  *(IMPLEMENTED, not deployed — see [DEVICE-KEY-CLAIM.md](DEVICE-KEY-CLAIM.md))*
Provisioning deadlocks: the key wants the TBFDesk id, the client shows no id until it is past the provisioning gate, and it cannot pass the gate without a key. Design (2026-10-16): an unbound key is a one-shot provisioning token; the first client that proves it **files a pending claim** the operator confirms or denies in the peers panel; only that confirmation writes the binding. A pending claim grants nothing, so it doubles as the "unverified client" view.
**Done 2026-10-16** (server `nemo-tdd`, client `nemo-tdd`): pending-claim store with per-key and global caps, both enforcement points converted to *prove → file a request → refuse*, approve/deny/forget/bind-by-hand routes, the confirm/deny UI in the peers panel **and** a pending section in the Device keys panel (the rendezvous handshake precedes `register_pk`, so a claim can name an unregistered id), a distinguishable 403 and a *"Waiting for approval by your administrator"* gate card in the Sciter client, and 96/96 tests — including the TASK #14 canary, green again **without** editing its assertion. `persist()` is now a no-op under `#[cfg(test)]`, which closes the hazard of a test writing `nemo_integration.json` into the checkout. **Open:** not deployed (the lab VM still runs `0747b0b`), no Flutter gate card, and the address-book/login endpoints still answer the generic 403. Full detail in `DEVICE-KEY-CLAIM.md`.

### 17. Windows: the installed client is **not findable as "TBFDesk"**  *(DONE + VERIFIED on Windows 2026-10-17)*
Confirmed on the test VM from the packaged installer: Start menu `TBFDesk\TBFDesk.lnk`,
desktop `TBFDesk.lnk`, Apps & Features **TBFDesk / TBFDesk / 1.4.7**, and the exe's
version info (`ProductName TBFDesk`, `FileDescription "TBFDesk Remote Desktop"`,
`OriginalFilename TBFDesk.exe`) — which is what Windows Search indexes.
**Done:** `DISPLAY_NAME`/`get_display_name()` in `common.rs`; the shortcut file names, the Start-menu folder and the uninstall `DisplayName`/`Publisher` use it; `build.rs` sets `ProductName`/`FileDescription`/`OriginalFilename`/`CompanyName`; the installer deletes the old `.lnk` names and the old Start-menu folder, and the uninstaller clears both names, so an upgrade does not leave two entries. `APP_NAME`, the config dir, the service, the registry key name, the exe file name and the URI scheme are untouched.
**The acceptance checks still have to be run on the test workstation** — this cannot be compiled or installed from the Linux dev box: search "TBF" in the Start menu, Apps &amp; Features, Explorer's Description column, and prove the ID and saved password survive the upgrade.

Original report:
Every OS-level label derives from `APP_NAME`, still `"RustDesk"` by design (`libs/hbb_common/src/config.rs:111`, via `common.rs:1064`; see 14 and `RENAMING-PLAN.md`). Windows Start-menu search indexes the **shortcut file name** and the exe's **version-info**, and both read RustDesk today:
- shortcuts are built as `{app_name}.lnk` / `Uninstall {app_name}.lnk` / `{app_name} Tray.lnk` (`src/platform/windows.rs:1572/1591/1622-1623`), where `app_name = get_app_name()`;
- `ProductName` / `FileDescription` / `OriginalFilename` fall back to winres defaults, i.e. to `Cargo.toml:2` `name = "rustdesk"` and `:7` `description = "RustDesk Remote Desktop"`, because `build.rs:41-47` sets only the icon and the manifest;
- plus hard-coded `…\RustDesk\…` staging paths at `windows.rs:1975-1976`.

**The point: this does not need the `APP_NAME` migration.** `RENAMING-PLAN.md` defers the rename because `APP_NAME` anchors the config dir, the service name and the registry — but none of those are what Windows *searches*. Separate the **display** name from the **identity** name:
- add `get_display_name()` → `"TBFDesk"` (new constant, `APP_NAME` untouched), used only for shortcut labels, the uninstall `DisplayName` **value** (the key *name* stays), the window title and the tray tooltip;
- in `build.rs`, set `ProductName` / `FileDescription` / `OriginalFilename` explicitly — three lines, and no crate rename (the plan recommends keeping `name = "rustdesk"`);
- **upgrade detail:** renaming the `.lnk` leaves the old `RustDesk.lnk` in place, so the installer must delete the old shortcut names or an upgraded machine shows *both* entries.

This is the cheap, non-breaking slice of what `RENAMING-PLAN.md` defers — recorded there as **Layer 0**.
**Acceptance:** typing "TBF" in the Start menu finds the client; Apps & Features shows TBFDesk; Explorer's Description column on the exe reads TBFDesk; config dir, service and registry are provably unchanged (no re-registration, ID and saved password survive).

### 18. Finish removing "RustDesk" from the program, the deployment and the operator steps  *(bucket 1 DONE 2026-10-16; buckets 2–3 open by design)*
**Done (bucket 1, user-visible labels):** 892 translated values across 49 locales; the three keys whose EMPTY value made English and German fall back to the key text (`About RustDesk`, `Keep RustDesk background service`, `Show RustDesk`); `res/` display fields (`.desktop` `Name`/`Keywords`, the service `Description`, `PKGBUILD` `pkgdesc`, the rpm specs' `Summary`/`%description`); one hard-coded Flutter window label. Kept on purpose: the AGPL attribution and the two `rustdesk.com/docs` links. Left alone with the reason recorded: `res/msi` (its `--app-name` substitution also renames the service and paths, so that is a bucket-2 change in disguise), `res/DEBIAN/*`, and **our own docs** — audited line by line, what remains is `%APPDATA%\RustDesk`, `RustDesk2.toml`, `RustDesk.exe`, `/tmp/RustDesk-<uid>`, the `FOCUS RustDesk` window class, host paths and upstream discussion, i.e. exactly the things #18 warns not to rename before Layer 2 ships. Per-file verdicts: `RENAMING-PLAN.md`.
**Bucket 2 DONE 2026-10-17** — `RENAMING-PLAN.md` Layers 1, 2, 4 and 5 shipped together
with the config migration (see **14**). What a user sees in Windows now reads TBFDesk from
the Start menu down to `C:\Program Files\TBFDesk\tbfdesk.exe`, the `TBFDesk` service and
`%APPDATA%\TBFDesk`. The docs this item warned not to rename early can now be corrected:
the runbooks that say `%APPDATA%\RustDesk`, `RustDesk2.toml`, `RustDesk.exe` and
`/tmp/RustDesk-<uid>` describe the pre-rename world and are wrong as of this release —
except where they describe the **live Linux server**, whose unit and binaries genuinely
are `rustdesk*` (that is Layer 3, still open).
**Open:** bucket 3 (upstream references — keep by design) and Layer 3 packaging.

Original report:
`RENAMING-PLAN.md` already specifies the app-side job (Layers 1–5 plus the migration, recommended *after* server-driven updates #5 exist). What the 2026-10-16 report adds is that the ask covers **deployment and the written steps**, not just the binary.

Measured state 2026-10-16 (lines matching `RustDesk|rustdesk`): `src/lang/de.rs` **1** — the German UI is effectively done; `src/lang` overall **952** (the other locales); `res/` **242** (`.desktop`, `PKGBUILD`, `DEBIAN`, `msi`, rpm/flatpak specs); `src/platform` **94**; `flutter/lib` **93**; `Cargo.toml` **28**; `src/ui` **16**. Our own docs/scripts still carrying the name: `DEPLOY.md`, `DEPLOYMENT-STEP-BY-STEP.md`, `HANDOFF.md`, `HANDOFF-WINDOWS-DIRECT.md`, `README.md`, `RUNBOOK-LOCAL-MODEL.md`, `LAB-VERIFICATION-2026-10-06.md`, `UPSTREAM-SYNC.md`, `e2e/*.ps1`, `scripts/vm-apply-server-address.sh`, `build-client-fast.cmd`.

**This is not a find-replace.** Triage the inventory into three buckets before touching anything:
1. **User-visible labels** → rename (the remaining locales, packaging display names, installer text, docs addressed to operators/users).
2. **Identity, paths, service and binary names** → only via `RENAMING-PLAN.md`'s migration; renaming these in docs *before* the code moves makes the runbooks wrong (the lab server's unit, binaries and paths genuinely are `rustdesk*` today).
3. **Upstream references** → **keep**: the `rustdesk-org` git dependencies, the `rustdesk`/`librustdesk` crate names, `UPSTREAM-SYNC.md`'s discussion of the upstream project, and the `rustdesk-client-nemo` / `rustdesk-server-nemo` submodule paths. Scrubbing these loses the provenance we need to keep merging upstream.

Do **17** first: it delivers the thing actually complained about (searchability) at a fraction of the risk.

---

## LOW — polish / housekeeping

### 27. Every tab label truncated on an installed client  *(DONE 2026-10-17, verified on Windows 11)*
Four tabs appear once the client is installed ("Im LAN erkannt" joins the other three),
and `MultipleSessions.onSize()` in `ab.tis` shared the row's width out between them in
proportion to each label's character count and set a hard `max-width`. With `@ELLIPSIS`
on the span that meant: as soon as the labels did not fit, **all four were cut** —
"Letzte Sitz… / Favor… / Im LAN e… / Adres…". German needs more room than English, so
that was the normal case on an installed German client, not an edge one.

`onSize()` and its `view.on("size")` hook are gone; with nothing clamping them the spans
are ordinary inline-blocks and the row wraps to a second line, every label whole. Do
**not** give `.sessions-tab` a wrapping `flow` to "help" — inside the horizontal
`.sessions-bar` with `width:*` both `horizontal-wrap` and `horizontal-flow` collapse it to
zero width and the tabs vanish entirely; tried both ways in the lab.

### 12. Settings dialog: swap **Alias** and **Direct IP access** between sections  *(DONE 2026-10-16, client `nemo-tdd`)*
Alias now sits under **Allgemein**, direct IP access (and its port row) under **Sicherheit & Netzwerk**, next to the IP whitelist that gates it. Not screenshot-verified — the Sciter UI cannot be built from the Linux dev box.
User request 2026-09-02, in `index.tis` `NemoSettingsDialog.render()`:
- **Alias** (`aRow("nemo-alias", …)`) moves from "Sicherheit & Netzwerk" (`sec`) → "Allgemein" (`gen`) — it's a friendly display name, not a security setting.
- **Direkten IP-Zugang aktivieren** (`tRow("direct-server", …)` + its dependent `aRow("edit-direct-port")`) moves from "Allgemein" (`gen`) → "Sicherheit & Netzwerk" (`sec`) — it IS a network/exposure setting.

### 13. About-dialog placeholder links  *(HANDLED 2026-10-16; still needs the real URLs)*
The three rows are now **omitted** rather than shown as "(wird ergänzt)" — a dialog that names a support channel and then says the address is missing is worse than one that does not mention it, because the reader cannot tell "not set up yet" from "we lost the page". Fill `NEMO_ABOUT_LINKS` in `index.tis` `showAbout()` (one array, label + URL; an empty URL hides its row) and the rows come back as real clickable links through the wiring that was already there. **What is still needed from TBF: the website URL, the support contact, the privacy-statement URL.**

### 14. `%APPDATA%` dir rebrand  *(DONE 2026-10-17 — RENAMING-PLAN Layers 1+2)*
`APP_NAME` is `TBFDesk`. The config directory, the file names inside it, the Windows
service, the registry key, the install directory, the exe, the IPC pipe, the logs and the
URI scheme all follow, and `Config::migrate_legacy_app_name()` carries an existing
install's ID, permanent password, device key and settings across — as a **copy**, so the
old directory remains the rollback path. Windows additionally gets
`get_legacy_cleanup()`: old service, both uninstall keys, `.rustdesk` / `rustdesk://`,
firewall rules, shortcuts and the old `C:\Program Files\RustDesk` all go.

Still open: **Layer 3** (packaging / bundle ids). On Linux the package is still
`rustdesk` — unit, desktop entry, `/etc/rustdesk/*`, pam — now pinned to a
`PACKAGE_NAME` constant instead of following `APP_NAME`, so an installed Linux client
keeps working. No Linux package is built from this tree today.

### 15. Inherited upstream code markers (informational)
- server `utils.rs:97/109/119` (OSX reverse-DNS, "ICMP ping?", "key check"); `rendezvous_server.rs:284` (`unreachable!()?`), `:1505` (udp self-poll workaround).
- client `client.rs:4138/4173` (socket-reuse micro-opt), `client.rs:122/3362` (Wayland login screen, upstream limitation).

---

## ✅ Recently closed (kept for context)
- **2026-09-02:** reload-icon root cause (onSize `max-width:0`); auto-update interval option + row dormant; About rebranded to TBF; **admin policy delivered user-overridable** (admins edit any setting locally; deployed); build-version readout (left pane + login gate); 176 checkout reconciled; LDAP service account **confirmed set** (`mstep@tbfgmbh.local`) — directory picker unblocked.
- **2026-09-02 (earlier):** encrypted direct-IP (B) + S-A fail-closed; require-encrypted fleet-wide; H1/M3/M4; 1% bitrate; multi-screen tiled view; settings modal dialog.

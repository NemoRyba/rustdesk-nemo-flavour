# TBFDesk security layers — requirement (2026-09-20)

Stated by the owner: *the offline-exchanged device key is mandatory and is verified before
the normal GUI starts; every client↔server exchange is protected with offline-exchanged
keys; LDAP user login is a server-enforced optional on top; later, the LDAP user is
auto-logged into the Windows session on the remote.*

## Layer 1 — device key (MANDATORY, client-enforced, before the GUI)

**Definition.** A per-machine Ed25519 keypair (`nemo-device-key`, 64-byte secret, public
half = bytes 32..64) generated on the server, pinned there (`device_keys` in
`nemo_integration.json`, dashboard "Device keys" panel) and delivered to the client out of
band. This is the "offline exchange". Without it a client is not a member of the fleet.

**Client behaviour.**
- On start, `App.render` checks for a usable device key FIRST — before the login gate. If
  absent, it renders a *provisioning gate only*: the "Import device key" dialog and the
  licence-name hint. No ID panel, no connect field, no address book, no menu. ("Before the
  GUI" cannot mean "before any window": the only import path is a dialog, so a keyless
  client must still be able to receive one.)
- Every management-plane request carries a device signature — the policy poll
  (`nemo-poll`), the address book (`nemo-ab`) and, NEW, the login (`nemo-login`). The
  sealed request envelope is mandatory whenever a management public key is configured.
- Provisioning paths that must all work behind the gate: the import dialog; the Windows
  licence-name bootstrap, which today provisions api-server + management public key but
  **not** the device key — extending it is a requirement (see Rollout).
- Verified: a key imported in the GUI reaches the `--server` process — `ui_interface::set_option`
  → `ipc::set_options` → service `Config::set_options` (`ipc.rs:933`).

**Server behaviour.** `require_device_key` and `strip_unsealed_secrets` default **true**.
A poll, address-book or login request without a valid, pinned device signature is refused.
The auth-mode column on the Peers dashboard (`record_peer_auth_mode`) shows `device-key`
or `default` per peer — it is the rollout instrument.

**What "encrypted with the offline-exchanged key" means, exactly.** Two offline-exchanged
keys are in play and the doc must not blur them:
- the **device key** proves the client's identity (signatures) and receives secrets
  (server→client responses are sealed to its Curve25519 form);
- the **management key** proves the server's identity (signs policy, the login key and
  the key-exchange offer) and receives the client's secrets (client→server envelopes are
  sealed to it).
The client→server envelope is a NaCl *sealedbox*, which is anonymous: it gives
confidentiality, and the device signature inside gives authenticity. A stricter single
primitive — NaCl `box_` keyed by (device secret, management public), so confidentiality and
sender authentication come from one operation — is the recommended follow-up while the
wire format is still uncommitted; it is not done tonight.

**Scope.** Layer 1 covers the management/API plane: poll, address book, login, update.
Rendezvous *registration* remains UDP plaintext by decision (see
SECURITY-AND-PERF-2026-09-20.md); TCP punch/relay/health-check are covered by
`--key-exchange`.

## Layer 2 — LDAP user login (OPTIONAL, server-enforced)

Unchanged mechanism: `require_login` on the server turns the login-first gate on; the
credential is sealed to the server's login key and, under layer 1, the request is also
device-signed, so a login can only come from a provisioned machine. When `require_login`
is off, layer 1 alone authenticates the machine and nothing falls back to `uuid`.

## Layer 3 — single sign-on into the remote Windows session (REQUIREMENT, not built)

Goal: the LDAP user who signed in to TBFDesk is logged in to the Windows session of the
workstation they connect to, without typing the password again.

Two workable designs, with very different blast radius:
1. **Credential forwarding.** The controller sends the domain credential (sealed in
   transit) to the controlled side, which performs an interactive logon (`LogonUser` /
   WinLogon via a credential provider). Simple; but a domain password exists in plaintext
   memory on the controlled machine, and every controlled machine becomes a place it can
   be stolen from.
2. **Ticket-based.** Kerberos: the server obtains a service ticket for the workstation on
   the user's behalf (constrained delegation / S4U2Proxy) and the controlled side's
   credential provider logs the user in with the ticket. No password ever reaches the
   workstation. Needs AD configuration (delegation rights for the TBFDesk service account,
   SPNs per workstation) and a custom credential provider.

**OWNER DECISION (2026-09-20): option 1, credential forwarding.** When LDAP is enabled, the
LDAP username+password the user already signed in with is forwarded to the controlled side and
used to log the same user into the remote Windows session automatically, so they reach their
desktop without re-typing. Accepted trade-off: the domain credential exists in memory on the
controlled machine during logon. Requirements that follow from this choice:
- The credential travels ONLY inside the existing sealed/encrypted session (never plaintext on
  the wire); it is handed to a Windows logon path (LogonUser / a credential provider or
  WinLogon automation) on the controlled side and not persisted to disk.
- It is used only when LDAP is enabled (layer 2 on); with LDAP off there is no user credential
  to forward, so auto-logon does not apply.
- Scope it to the connecting user; do not cache or reuse it for later sessions.

**Nice-to-have (owner, 2026-09-20): "who is already on this computer".** The client GUI should
show, before/around connecting, whether a user is currently logged in / actively using the
target (so an operator does not interrupt someone). The data is distributed by the server:
the controlled side already reports to hbbs (hostname via the policy poll); extend that with a
session-status field (logged-in user / locked / idle-vs-active / active console session), the
server aggregates it, and the address book / connect view surfaces it per peer. This is
presence metadata, not control, so it rides the same management-plane channel and needs no new
trust. Keep it advisory (a hint), and consider whether the logged-in username is sensitive
enough to gate behind an operator permission.

## Auto-update (folded in, because it is a layer-1 consumer)

The stock updater must be unreachable: no `api.rustdesk.com`, no policy key that can turn
the upstream path on. Updates come only from the management server: a signed manifest
`{version, url, sha256, sig}` where `sig` is the management Ed25519 key over
`version|url|sha256`; the client verifies the signature with its pinned management public
key, verifies `url` is on the management server origin, verifies the artifact's SHA-256,
and only then hands it to the existing (Windows) installer path. Enabled by a Nemo policy
key, never by the stock `allow-auto-update`.

## Rollout — mandatory does not mean "flip it blind"

1. Provision every peer. Watch the Peers dashboard until the auth-mode column reads
   `device-key` for all of them. Any `default` is a machine that will be locked out.
2. Deploy the client build with the provisioning gate.
3. Deploy the server build whose defaults are `require_device_key=true`,
   `strip_unsealed_secrets=true`.
4. Windows licence-name bootstrap must be able to carry the device key (a `devkey=` field)
   so a renamed exe fully provisions a machine — until it does, the import dialog is the
   only path on a fresh machine.

---

## Implementation status (2026-09-20, uncommitted on nemo-tdd)

**Layer 1 — device key mandatory: IMPLEMENTED + LIVE-VERIFIED.**
- Client: provisioning gate in `App.render` (renders before the login gate; a keyless client
  shows only "This device is not set up yet" + Import button). Verified rendering on Debian
  (screenshot) — no throw, German button text present.
- Client: the sealed request envelope is now mandatory whenever a management key is set (no
  plaintext fallback); the sealed login carries a `nemo-login` device signature.
- Server: `require_device_key` and `strip_unsealed_secrets` now default **true** on a fresh
  config (verified via /nemo/api/health on a clean lab server). An existing
  nemo_integration.json keeps its stored values (rollout guard).
- **Live differential test against a loopback hbbs:**
  - `require_device_key=true`  → login refused: *"This server only accepts sign-ins from a
    provisioned computer. Import the device key…"* (layer 1 blocks first)
  - `require_device_key=false` → *"LDAP integration is disabled"* (only then is layer 2 reached)
  This proves device-key-first, LDAP-optional-on-top exactly as specified.
- Builds: server 62/62 tests; client 75/75 tests (release, all codecs). Both compile clean.

**Auto-update — management-server-only: IMPLEMENTED.**
- Client `do_check_software_update` now GETs `<mgmt-server>/nemo/api/update/latest` and verifies
  the manifest's Ed25519 signature against the pinned management key, checks the URL is on the
  management origin, and (in updater.rs) verifies the downloaded artifact's SHA-256 before the
  installer runs. The stock `api.rustdesk.com` path has no caller left; the stock
  `allow-auto-update` key stays in POLICY_DENIED_KEYS. Our updater is gated on `nemo-auto-update`.
- Server serves/serves-signed the manifest from `nemo_update.json` (admin POST /nemo/api/update
  publishes it; GET /nemo/api/update/latest returns it + a fresh signature; 404 when none).

**Rendezvous key exchange (scope c) — LIVE-VERIFIED.** With `--key-exchange offer` the server
sends a 103-byte KeyExchange frame on TCP accept whose ephemeral key is correctly Ed25519-signed
by the rendezvous key (verified over a raw socket). The login-encryption key from
`/api/login-key` is likewise correctly signed (a MITM cannot substitute its own).

### Known gaps (must close before shipping mandatory)
1. **Service-provisioned key freshness.** A device key written by the `--server` process
   (licence-name bootstrap, or a future push) is NOT seen by the GUI's `nemo_device_key_present()`
   until the binding also consults `ui_interface::get_option("nemo-device-key")` — the GUI's
   CONFIG2 is a process-static loaded once. The **import-dialog** path works today (writes
   locally). Fix: have the ui.rs binding OR its way through `ui_interface::get_option`.
2. **Licence-name bootstrap does not carry the device key.** It provisions api-server + mgmt key
   but not `nemo-device-key`; add a `devkey=` field so a renamed exe fully provisions a machine.
   Until then, the import dialog is the only path on a fresh machine.
3. **Layer 3 (SSO into the remote Windows session) — NOT built.** Blocked on the owner's
   password-vs-Kerberos decision (see above).

## Test lab (reproducible, no VM)
- Server: `hbbs -k _ --nemo-api Y --nemo-api-bind 127.0.0.1:21120 --nemo-api-token <t>
  --nemo-api-allow-insecure Y --key-exchange offer` in an empty working dir (fresh config →
  new defaults). Management API is plain HTTP on loopback (LDAP off), so `curl` drives it.
- Provision a key: `POST /nemo/api/device-keys {"label":..,"peer_id":..}` → returns the private
  key to import client-side (`nemo-device-key`).
- GUI: `Xvfb :99`, run the client with `GDK_BACKEND=x11 DISPLAY=:99` and `env -u WAYLAND_DISPLAY`,
  Sciter runtime `libsciter-gtk.so` (sciter-sdk bin.lnx/x64), launch from the repo root so the UI
  html resolves. Debug builds panic in rust-sciter's flag transmute under modern rustc — use a
  **release** build for GUI runs. The `--server` role needs a tray host (StatusNotifierWatcher)
  which Xvfb lacks; the controller GUI does not.

# RustDesk Nemo TODO

> ⚠️ **TOP PRIORITY:** [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) — make every channel (shell, desktop, file transfer, LDAP login) provably encrypted and MITM-proof, on par with AnyDesk/TeamViewer. Priority order: Performance ▸ Security ▸ Usability.
> 📋 **Ranked open work:** [OPEN-TODOS.md](OPEN-TODOS.md) — server-driven client updates, relay-vs-direct metrics, identity-field hardening, ops items. · **Rename plan:** [RENAMING-PLAN.md](RENAMING-PLAN.md) — how to fully rename RustDesk→TBFDesk without breaking installs.

## Done (management layer — built, deployed, verified)

- Server-driven **LDAP/AD login** (LDAPS + cert pinning) + server-populated **address book**, per-user RBAC, HTTPS on the management/login API.
- **Login-first client** gate + stale-session self-heal; identity token now correctly transmitted (poll + rendezvous punch read it from LOCAL config).
- **ACL tab** (require-login, allowlist with per-user targets/policy) + **Integration → Directory-users picker** (service-account directory search; only selected users may sign in; no auto-populate).
- Per-user **connection ACL** enforced at the rendezvous punch.
- **Address book shows ID + hostname** (each host reports its hostname via its policy poll; store persisted server-side).
- Adjustable 1/2/3-column dashboard layout; UAC-install + upstream-update banners removed from the client home.
- User-visible strings rebranded **TBF/TBFDesk** ("Nemo" kept only in code/filenames).

## Done (2026-09-25, completed 2026-09-27)

- **H11/H20/H22:** ACL version check against stale-tab overwrites — server `0231ccd`, contract fixed in `897a00b`.
- **H23/M13:** login sessions evicted when a user's permissions change.
- **H24:** client `9e18fa9e1` reverted in `feaf523f9` — the socket was already 0600/0700, and the check broke root CLI commands.

S-B sealing, M1, S-C, A4 and the L-items are the 2026-09-03 work in SECURITY-HARDENING-TODO.md.

## Done (2026-09-27/28, the full re-sweep)

- **CRITICAL:** port-forward/RDP tunnels now stay encrypted end to end (client `ad7a72f95`); 1-byte frames no longer bypass decryption (hbb_common `11ce3a9`/`1d49321`).
- **HIGH:** missing signing key now stops hbbs/hbbr instead of minting a new one (server `469ac91`); stolen login tokens can't be replayed from another device on `/api/ab/get` or the policy poll, permission changes and device-key revocation now end live sessions, sealed login required by default (server `e962e36`); the client's TLS-fallback default is closed automatically via a server-pushed certificate pin (server `8007c34`); the client has no plaintext login fallback (client `d57037a47`).
- **MEDIUM:** the settings dialog can no longer revert server-managed security state (client `fe84e78f3`); relay grants are minted only for sessions hbbs actually brokered (server `ef2fca7`); the integration config and sessions file are now written crash-safely (server `ef2fca7`); hbbs no longer phones home to api.rustdesk.com (server `c14d6c9`).
- A locally-run "IPC authorization" change turned out to protect nothing (the socket was already 0600) and broke root CLI commands; reverted (client `feaf523f9`).

Full detail, evidence and the still-open items: `../OPEN-POINTS-2026-09-21.md`.

## Done (2026-09-28, later)

- R6-2 removed: a user repointing their own client at a different server/key is
  intended, not a defect.
- R6-7: hbbs's key-generation race (two processes on a fresh host could each mint a
  different key) closed with an atomic `hard_link` publish, no lock -- a threaded
  test proves it can't deadlock and always converges on one key.
- R6-13: `--option` with no key crashed; `--option key --force` wrote the literal
  string "--force" as the value. Both fixed.
- R6-14: the "Import device key" dialog now validates a paste against the real
  Ed25519 seed-derivation the server's own key generator uses, before committing it.

## Open

- Set a read-only **service account** (Bind DN + password) in Integration → LDAP so the directory picker can list domain users.
- Client **window title** still "RustDesk" (APP_NAME rebrand deferred — needs `%APPDATA%` config migration).
- The 176 Linux host has only its policy-poll file updated (still base `10fc2b22f`); a full-parity Linux client would need a base-commit sync.

## Later Integration

- Integrate the existing separate VPN-based 3D AutoCAD mouse solution into the RustDesk-based all-in-one remote workstation setup.
  - Current state: separate working solution exists and is used in production.
  - Reason: 3D AutoCAD mouse support did not work reliably in the tested remote desktop products.
  - Next input needed: implementation details/protocol/device handling from the current solution.

## Current Focus

- Establish the best network topology for high-performance direct RustDesk access to workstation PCs.
- Avoid relay paths for AutoCAD/3D work unless used only as a fallback.
- Validate client/server builds in a Linux VM or Docker before returning to Windows packaging.

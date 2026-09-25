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

## Done (security fixes — implemented 2026-09-25, committed and pushed)

- **H11/H20/H22:** ACL version check to prevent stale tab overwrites (`permissions_version` field + mismatch rejection).
- **H23/M13:** Session eviction when permissions change (user removed, disabled, targets changed, admin flag changed, policy changed).
- **H24:** IPC authorization for Linux/macOS main IPC (same user or root required, executable matches).
- **S-B control-plane sealing:** Policy poll response sealed to device key (`sealed_payload`); request can carry sealed token; address book sign-then-sealed; login sealed with nonce.
- **S-C:** LDAP cert verification off-switch fails closed (requires `--insecure-ldap-i-accept-mitm Y`).
- **M1:** Device keys bound to peer id (one leaked key no longer authenticates fleet-wide).
- **A4:** Cert-fingerprint pinning (`PinnedVerifier` + `nemo_api_cert_fingerprint` policy key).
- **L-items:** Admin API fails closed without token; sealed-login replay guard (nonce); user enumeration collapsed; device-key collision fixed; unsigned-policy compiled out of release.

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

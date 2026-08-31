# RustDesk Nemo TODO

## Done (management layer — built, deployed, verified)

- Server-driven **LDAP/AD login** (LDAPS + cert pinning) + server-populated **address book**, per-user RBAC, HTTPS on the management/login API.
- **Login-first client** gate + stale-session self-heal; identity token now correctly transmitted (poll + rendezvous punch read it from LOCAL config).
- **ACL tab** (require-login, allowlist with per-user targets/policy) + **Integration → Directory-users picker** (service-account directory search; only selected users may sign in; no auto-populate).
- Per-user **connection ACL** enforced at the rendezvous punch.
- **Address book shows ID + hostname** (each host reports its hostname via its policy poll; store persisted server-side).
- Adjustable 1/2/3-column dashboard layout; UAC-install + upstream-update banners removed from the client home.
- User-visible strings rebranded **TBF/TBFDesk** ("Nemo" kept only in code/filenames).

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

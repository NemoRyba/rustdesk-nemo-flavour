# TBFDesk — Open TODOs (ranked by relevance to the goal)

**Goal:** a performance-oriented, centrally-managed, **direct** remote-control product.
**Priority order:** Performance ▸ Security ▸ Usability/manageability.
**Companion docs:** [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) (transport security), [TODO.md](TODO.md) (running log), `.claude/plans/analyze-this-repository-and-fizzy-parrot.md` (full roadmap).

---

## ✅ Just done (2026-09-02)
- **Encrypted DIRECT-IP (B)** + **S-A closed / fail-closed** — direct-IP sessions now encrypt end-to-end with no relay, server-anchored via a signed `nemo-peer-keys` map; `require-encrypted-session` enforced fleet-wide; every plaintext fail-open path (H2/H3) removed. Deployed (server live on .176). See [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) 2026-09-02 section.
- **Bug-hunt fixes:** H1 (stop logging session token), M3 (0600 on LDAP/session files), M4 (test suite compiles again — 41 pass).
- **UX:** 1% custom bitrate floor; multi-column settings menu (needs visual check).
- **Docs:** [SPEED-AND-CODEC-RESEARCH.md](SPEED-AND-CODEC-RESEARCH.md) (TJPEG_V2/DWService codec + speed opts). Multi-screen tiled view implementation in progress (Sciter UI; needs visual test).

## ✅ Just done (2026-09-01)
- **Named/per-user policies** now expose the already-enforced capability keys: **Camera, Remote terminal/shell, TCP tunnel, Remote printer** (+ **one-way file transfer** earlier). All are `KEYS_SETTINGS`-scoped and already gated on the controlled side — pure dashboard, zero client change.
- **TBFDesk rebrand** of the remaining user-visible strings (About/version/tray/toast/German + settings help); `APP_NAME` stays `RustDesk` (config dir/service/protocol unchanged).
- Named policies (create + assign to **users** and **devices**, precedence user ▸ device ▸ global) — verified end-to-end.

---

## HIGH — biggest gaps for a managed, direct fleet

### 1. Server-driven client updates / rollout  *(does not exist)*
For a managed fleet, pushing a new client version **from the server** is the single biggest missing management capability. The upstream updater is dead-coded (`updater.rs:31/36/43` `#[allow(dead_code)]`) and points at `api.rustdesk.com` — which this fork **blocks** (`common.rs:2059` `nemo_public_network_blocked()==true`). No update/version/download route exists on the nemo-api.
**Build on what already works:**
- Admin sets a **target version + download URL** (global and/or per-peer) in the dashboard.
- Clients learn it via the **existing signed client-policy poll**, compare to `handler.get_version()`, download, and install.
- **Sign the binary** with the server keypair (reuse the Ed25519 policy-signing path) so the client verifies authenticity before installing — no plaintext-URL trust.
- Host the binaries on the **api-server (:21120)**; silent/unattended install needs the installed-service path (same constraint as managed passwords).
**Perf:** none (control-plane only).

### 2. Security hardening → see [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md)
The core session is already E2E-strong; the ranked fixes there are the HIGH security work:
- **S-A** peer-key trust fails open → ✅ **CLOSED 2026-09-02** (require-encrypted fail-closed + server-anchored encrypted direct-IP). Remaining: TOFU store for peers not in the pushed map (they fail closed today).
- **S-B** management/LDAP-login API is **self-signed accept-any-invalid TOFU** → CA-signed or fingerprint-pinned cert, fallback OFF. *(critical — LDAP password confidentiality)*
- **S-C** LDAP DC cert-verify off-switch. **S-D** cross-direction nonce reuse. **S-E** port-forward/RDP tunnels drop the E2E layer.

---

## MED — serve "performance / prove-it-stays-direct" and robustness

### 3. Relay-vs-direct **byte** metrics  *(observability)*
Today you can see *why* a session was forced to relay (negotiation events from hbbs), but **not how much traffic used the relay** — the byte counters live inside `hbbr` and aren't surfaced (`docs/nemo-management-api.md:151-153`). To *prove* sessions stay direct (the whole point), expose per-session relay byte counts from hbbr to the dashboard.

### 4. Harden the controller-identity field  *(protocol robustness)*
Per-user ACL / require-login enforcement rides inside the untyped rendezvous `version` string as `nemo-source-v1:<id>:<uuid>` (`nemo_management.rs` `controller_source_identity`). It works, but a **real protobuf field** (`message NemoSource { string id; bytes uuid; }` on `PunchHoleRequest`/`RequestRelay`) would make it robust and closes the advisory-policy bypass. This is Phase 1.3 / S2 in the plan (forks `hbb_common`).

---

## OPS / enablement (no code, or tiny code)

### 5. LDAP read-only **service account** still unset  *(blocks the directory picker end-to-end)*
Set a Bind DN + password in Integration → LDAP so the directory search can list domain users (the picker currently reports "needs a service account"). Also finish pointing clients' `api-server` at `https://<host>:21120` (pushable via global policy).

### 6. Linux client **base-commit parity** on `.176`
The `.176` Linux host only has its policy-poll file updated (base `10fc2b22f`); a full-parity Linux client needs a base-commit sync + rebuild (Rust 1.75 + Sciter) to match the Windows feature set for managed control of Linux hosts.

### 7. `%APPDATA%` dir rebrand (deferred)  *(cosmetic)*
`APP_NAME` stays `RustDesk` so the config dir/service/registry are unchanged. A true dir rename needs a config-migration step; low priority.

---

## LOW — TBFDesk polish
- **About-dialog placeholders** (`index.tis` `MyIdMenu.showAbout()`): the RustDesk links/branding were removed (2026-09-02) and replaced with TBF placeholders — fill in the real **TBF website URL, support/contact info (e-mail, phone), privacy-statement link** when available, and wire them as clickable `.link .custom-event url='…'` divs (the click handler is already in place).

## LOW — upstream TODO/HACK markers in retained code (informational)
These are inherited from upstream RustDesk, not TBFDesk work, and are low-relevance to the goal:
- `rustdesk-server-nemo/src/utils.rs:97` reverse-DNS on OSX; `:109` "ICMP ping?"; `:119` "key check".
- `rustdesk-server-nemo/src/rendezvous_server.rs:284` `// unreachable!() ?` (UDP recv None branch); `:1505` `// temp solution to solve udp socket failure` (hbbs self-poll).
- `rustdesk-client-nemo/src/client.rs:4138` "Use long connections to avoid socket creation"; `:4173` "Make sure socket closed?" (socket-reuse micro-opt; marginally perf-relevant, generic).
- `rustdesk-client-nemo/src/client.rs:122, 3362` Wayland login screen "not supported" (upstream platform limitation).

---

## Deferred / product-level
- **3D AutoCAD mouse integration** — blocked on the protocol details of the existing VPN solution (needs user input).
- **Flutter UI parity** — Sciter is the active/working UI; Flutter is deprecated upstream. Not pursued.

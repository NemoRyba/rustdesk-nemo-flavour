# TBFDesk — Open TODOs (ranked, **each item verified against code/live state on 2026-09-02**)

**Goal:** a performance-oriented, centrally-managed, **direct** remote-control product.
**Priority order:** Security edge ▸ Management capability ▸ Performance observability ▸ Polish.
**Companion docs:** [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) (transport security detail), [HANDOFF.md](HANDOFF.md) (session state + recipes), `TODO.md` (running log), `.claude/plans/analyze-this-repository-and-fizzy-parrot.md` (full roadmap).

---

## SECURITY — verified open

### 1. S-B + H4 — trust for the management control plane  *(the one real security edge left)*
*Verified:* clients run with `allow-insecure-tls-fallback = 'Y'` against the self-signed `--nemo-api-tls auto` cert, and the policy response delivers secrets (e.g. `nemo-permanent-password`) unsealed, authenticated only by id+uuid.
**Fix as one design:** CA-signed or fingerprint-pinned cert with the insecure fallback OFF, and seal the policy-poll response (+ `/api/ab/get`) to the provisioned device key (S-DUALKEY step 3). Closes S-B and H4 together.

### 2. M1 — device keys are a shared pool
*Verified:* `verify_device_key` only checks `is_device_key_pinned(pubkey)` — any pinned key authenticates any client id. Bind each key to a peer id at provisioning time.

### 3. M2 — blocklist trusts a self-reported id
*Verified:* the controlled side rejects blocked peers on `lr.my_id`, a field the CONNECTING client fills in. Now fixable properly: anchor on the B-feature SignedId (server-pushed `nemo-peer-keys`).

### 4. Smaller hardening (per the 2026-09-01 audit)
- **S-C**: the LDAP `tls_verify` off-switch exists (default true, verified) — remove or admin-gate it.
- **S-D**: cross-direction nonce reuse on the shared secretbox key (primitive-level).
- **S-E**: port-forward/RDP tunnels drop the E2E layer.
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

### 7. Relay-vs-direct **byte** metrics
*Verified:* `relay_server.rs` exports no per-session byte counters. To PROVE sessions stay direct, surface hbbr per-session relay bytes to the dashboard.

### 8. `NemoSource` protobuf field  *(protocol robustness)*
*Verified:* controller identity still rides smuggled in the rendezvous `version` string (`nemo-source-v1:<id>:<uuid>[:token]`). A real field on `PunchHoleRequest`/`RequestRelay` closes the advisory-policy bypass. Forks `hbb_common` → do together with #9.

### 9. hbb_common fork remote  *(blocks fresh clones)*
*Verified:* `libs/hbb_common`'s only remote is read-only upstream `rustdesk/hbb_common`; local commit `40adca6` (private-network-only + quality default) is unpushed. Create a NemoRyba fork, push, repoint the submodule URL — until then recursive clones can't resolve the gitlink and the 176 checkout shows it permanently modified.

### 10. Rebuild the 176 Linux host binary  *(checkout is current, binary is not)*
*Verified:* client checkout on 176 reconciled to `nemo-tdd` HEAD on 2026-09-02, but `/opt/nemo-rustdesk/rustdesk` is dated 2026-08-31. Rebuild (Rust 1.75, `inline,linux-pkg-config`) and atomic-replace + `systemctl restart rustdesk-nemo.service`.

---

## NEEDS THE USER / infrastructure (not verifiable from the dev box)

### 11. WAN/NAT path measurement + per-workstation codec tuning
Needs the real double-NAT topology and a person at both ends (e2e/ harness is ready). Related: both OpenWrt 19.07.1 routers are EOL — upgrade (S10) before topology changes.

---

## LOW — polish / housekeeping

### 12. Settings dialog: swap **Alias** and **Direct IP access** between sections
User request 2026-09-02, in `index.tis` `NemoSettingsDialog.render()`:
- **Alias** (`aRow("nemo-alias", …)`) moves from "Sicherheit & Netzwerk" (`sec`) → "Allgemein" (`gen`) — it's a friendly display name, not a security setting.
- **Direkten IP-Zugang aktivieren** (`tRow("direct-server", …)` + its dependent `aRow("edit-direct-port")`) moves from "Allgemein" (`gen`) → "Sicherheit & Netzwerk" (`sec`) — it IS a network/exposure setting.

### 13. About-dialog placeholder links
"Webseite/Support/Datenschutz: (wird ergänzt)" — fill in the real TBF website URL, support contact, privacy link; the clickable `.link .custom-event url='…'` wiring is already in place (`index.tis` `showAbout()`).

### 14. `%APPDATA%` dir rebrand (deferred, cosmetic)
`APP_NAME` stays `RustDesk` so config dir/service/registry are unchanged; a true rename needs a config-migration step.

### 15. Inherited upstream code markers (informational)
- server `utils.rs:97/109/119` (OSX reverse-DNS, "ICMP ping?", "key check"); `rendezvous_server.rs:284` (`unreachable!()?`), `:1505` (udp self-poll workaround).
- client `client.rs:4138/4173` (socket-reuse micro-opt), `client.rs:122/3362` (Wayland login screen, upstream limitation).

---

## ✅ Recently closed (kept for context)
- **2026-09-02:** reload-icon root cause (onSize `max-width:0`); auto-update interval option + row dormant; About rebranded to TBF; **admin policy delivered user-overridable** (admins edit any setting locally; deployed); build-version readout (left pane + login gate); 176 checkout reconciled; LDAP service account **confirmed set** (`mstep@tbfgmbh.local`) — directory picker unblocked.
- **2026-09-02 (earlier):** encrypted direct-IP (B) + S-A fail-closed; require-encrypted fleet-wide; H1/M3/M4; 1% bitrate; multi-screen tiled view; settings modal dialog.

# TBFDesk — Open TODOs (ranked, **each item verified against code/live state on 2026-09-02**)

**Goal:** a performance-oriented, centrally-managed, **direct** remote-control product.
**Priority order:** Security edge ▸ Management capability ▸ Performance observability ▸ Polish.
**Companion docs:** [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) (transport security detail), [HANDOFF.md](HANDOFF.md) (session state + recipes), `TODO.md` (running log), `.claude/plans/analyze-this-repository-and-fizzy-parrot.md` (full roadmap).

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

### 7. Relay-vs-direct **byte** metrics
*Verified:* `relay_server.rs` exports no per-session byte counters. To PROVE sessions stay direct, surface hbbr per-session relay bytes to the dashboard.

### 8. `NemoSource` protobuf field  *(protocol robustness)*
*Verified:* controller identity still rides smuggled in the rendezvous `version` string (`nemo-source-v1:<id>:<uuid>[:token]`). A real field on `PunchHoleRequest`/`RequestRelay` closes the advisory-policy bypass. Forks `hbb_common` → do together with #9.

### 9. hbb_common fork remote  ✅ RESOLVED 2026-09-03
Forked to **github.com/NemoRyba/hbb_common** (public) + a **176 bare mirror** (`~/git/hbb_common.git`). The `nemo` branch (`40adca6` + A4 `b6aa3ca`) is pushed to both; the client `.gitmodules` now points at NemoRyba (branch `nemo`) and the gitlink is committed (`ef99cce88`, pushed to NemoRyba + 176). Fresh recursive clones now resolve. hbb_common remotes: `origin`=NemoRyba, `ubuntu`=176, `upstream`=rustdesk/hbb_common.

### 10. Rebuild the 176 Linux host binary  *(checkout is current, binary is not)*
*Verified:* client checkout on 176 reconciled to `nemo-tdd` HEAD on 2026-09-02, but `/opt/nemo-rustdesk/rustdesk` is dated 2026-08-31. Rebuild (Rust 1.75, `inline,linux-pkg-config`) and atomic-replace + `systemctl restart rustdesk-nemo.service`.

---

## NEEDS THE USER / infrastructure (not verifiable from the dev box)

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

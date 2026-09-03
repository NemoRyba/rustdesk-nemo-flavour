# TBFDesk — Security Hardening TODO (MUST-DO, top priority)

**Owner:** TBF · **Status:** OPEN · **Created:** 2026-09-01 · **Grounded in a full code audit of the fork (client + server).**

## The mandate
Every remote communication channel — **remote shell**, **remote desktop** (screen / input / clipboard), **file transfer**, and **LDAP login** — MUST be provably **encrypted and secure**, at least **on par with AnyDesk / TeamViewer**.

**Priority order (do not reorder):**
1. **Performance — primary.** Direct connections first, relay only as fallback.
2. **Security — second.** This document. Must reach enterprise parity.
3. **Usability / central manageability — third.**

**Non-negotiable design rule:** none of the fixes below may touch the streaming hot path. Every item here acts **once per session at connection setup / key exchange / TLS handshake**, not per video frame or per file block. After each change, re-run the `e2e/` harness (`measure-connection.ps1`) and confirm **no setup-time or throughput regression** vs the committed baseline. Security must not cost performance.

## ⛔ P0 PRODUCTION MANDATE — no plaintext control-plane on the internet
**Before this goes to production: EVERY client↔server channel that can be encrypted MUST be encrypted. No information travels over the internet in the clear — ever.** This is not just the LDAP login; it covers the whole control plane:

| Endpoint | Direction | Sensitive content today |
|---|---|---|
| `/api/login` | client → server | **domain username + password** |
| `/nemo/api/client/policy` (poll) | client → server | session **access_token**, id, uuid, hostname |
| `/nemo/api/client/policy` (poll) | server → client | pushed **managed password** (`nemo-permanent-password`), all pushed config — **signed, but not encrypted today** |
| `/api/ab/get` | server → client | full **address book** (peer ids, aliases, hostnames) |
| `/api/currentUser`, `/api/logout` | both | token, identity |

Requirement: confidentiality must **NOT depend on TLS PKI alone**. Reuse the keys the fork already trusts — the client's **registered device keypair** (RegisterPk) and the server's **Ed25519 signing key** — to seal each direction to the counterpart's key (NaCl `box_`/`sealedbox`), so a MITM (even under a forged/self-signed cert) sees only ciphertext. **TLS stays on as defense-in-depth.** Tracked as **S-B** (login) extended to the full control plane below. Acceptance: a packet capture of every control-plane call in production shows **no readable credential, token, password, or peer list** — only ciphertext.

---

## Current state (audited 2026-09-01) — what is ALREADY strong

The **peer↔peer session is genuinely end-to-end encrypted**, and this is comparable to or cleaner than AnyDesk/TeamViewer:

- **Cipher:** NaCl `secretbox` = **XSalsa20-Poly1305** (`libs/hbb_common/src/tcp.rs:296-321`).
- **Key exchange:** a random secretbox key sealed with NaCl `box_` (**X25519** sealed box) to the controlled peer's **ephemeral** public key — per-connection ephemeral keypairs give **effective forward secrecy** (`common.rs:2024-2031` → `tcp.rs:323-343`, controlled side `server.rs:227-231`).
- **Identity:** controlled peer signs its `(id, pubkey)` with a long-term **Ed25519** key, verified by the controller (`server.rs:200-219`, `common.rs:2013-2022`).
- **The relay (hbbr) is a blind byte-forwarder** — it never holds a session key and only ever sees ciphertext + the licence_key/uuid pairing metadata (`relay_server.rs:425-566`). E2E is preserved through relay.
- **All the sensitive channels ride inside that one encrypted stream:** video, input, clipboard, **file transfer** (`connection.rs:2990`), **terminal/shell** (`connection.rs:3483`). Transport-level encrypt/decrypt in `FramedStream` (`tcp.rs:158-188`).

**Verdict:** the core remote-control channel is strong. The gaps are at the **trust / TLS / key-pinning edges**, and in two protocol details. Those are what this TODO fixes.

### Encryption matrix (as-audited)
| Channel | E2E encrypted today? | Mechanism / caveat |
|---|---|---|
| Remote desktop (video/input/clipboard) | ✅ Yes | secretbox inside the session stream |
| **File transfer** | ✅ Yes | rides the same encrypted stream (`connection.rs:2990`) |
| **Remote shell / terminal** | ✅ Yes | rides the same encrypted stream (`connection.rs:3483`) |
| Port-forward / RDP tunnel | ⚠️ **No secretbox** | peers call `set_raw()` after login (`port_forward.rs:190`, `connection.rs:1216`); relies on the inner protocol (e.g. RDP's own TLS) — see **S-E** |
| LDAP login (`/api/login`) password | ⚠️ **TLS-only** | confidentiality depends entirely on the API TLS (self-signed TOFU today) — see **S-B** |
| Management/policy payload | ✅ Signed | Ed25519 signature, unsigned refused (`nemo_management_client.rs:181-204`) — integrity strong; but see **S-B** for confidentiality |
| Server↔DC (LDAP) | ✅ `ldaps://` enforced | but a cert-verify **off-switch** exists — see **S-C** |

---

## The work — ranked (highest security impact first)

### S-A — CRITICAL: peer-key trust fails OPEN (silent downgrade to plaintext)
**Problem.** Peer identity is anchored only in the rendezvous key (`RS_PUB_KEY`), **not pinned per peer**. On a key mismatch the controller **does not abort** — it logs `"pk mismatch, fall back to non-secure"`, sends an **empty** `PublicKey`, and the controlled side proceeds with **NO session key = plaintext** (`client.rs:872-877` → `server.rs:232-234`). The only signal is a UI `is_secured=false` flag. This is exactly the "unpinned/mismatched key must not authenticate" risk: it neither authenticates nor hard-fails — it **silently degrades to unencrypted**.
**Fix.**
1. **Pin** each controlled peer's public key on first accepted connect (real TOFU store, per peer id).
2. **Fail CLOSED** on any subsequent mismatch — refuse the session, surface a clear warning; never downgrade to plaintext.
3. Add a policy switch `nemo-require-encrypted-session=Y` (default ON) that removes the plaintext fallback entirely for the company fleet.
**Parity note.** AnyDesk/TeamViewer pin the peer key and hard-fail. This is the single biggest gap.
**Perf:** setup-only; zero hot-path cost.

### S-B — CRITICAL: encrypt the ENTIRE control plane (login + policy poll + address book), not just self-signed TLS
**Problem.** The nemo-api serves an **rcgen self-signed** cert (`nemo_management.rs:738`). To make clients accept it you must enable `allow-insecure-tls-fallback`, whose implementation is **accept-ANY-invalid-cert-and-remember** (`tls.rs:84-98`, `common.rs:1536-1572`) — **TOFU without pinning**; a MITM presenting any self-signed cert is accepted on first and every connect. Consequences today: (a) **`/api/login`** domain password confidentiality depends entirely on this TLS; (b) the **policy poll** carries the session **token** up and, critically, pushes the **managed password + config down — Ed25519-*signed* but NOT *encrypted*** (a MITM under insecure-fallback reads the pushed password); (c) **`/api/ab/get`** returns the whole address book. Per the **P0 mandate**, none of this may be in the clear in production.
**Fix — PREFERRED: ride on the keys we already trust (no CA/PKI dependency).**
The client already holds and trusts the server's **Ed25519 key** (`nemo-management-public-key`) — it verifies every signed policy with it. Use that same trust anchor to make the credential confidential *independently of TLS*:
1. **Seal the login credential to the server's public key.** Client encrypts `{username, password}` with a NaCl **sealed box** (`crypto_box_seal`, sodiumoxide `sealedbox`) to the server's Curve25519 key — either convert the Ed25519 key via `crypto_sign_ed25519_pk_to_curve25519`, or have the server publish a dedicated X25519 "login" pubkey in the health/policy response (already Ed25519-signed, so its authenticity is covered). **Only the server's private key can open it.** Now a MITM — even under `allow-insecure-tls-fallback` or a forged cert — sees only ciphertext. This reuses the exact primitives and trust already in the product (same NaCl `box_` as the peer session, same key as policy signing), so it needs **no CA, no cert store, no PKI** — which is why it fits a private fleet better than public-CA TLS.
2. Add a **replay guard** (client nonce/timestamp inside the sealed payload, server rejects stale/duplicate) so a captured blob can't be re-POSTed.
3. **Extend the same sealing to the WHOLE control plane (P0 mandate), both directions:**
   - **Client → server** requests: seal the secret fields (session **token**, credentials, uuid) to the server key on `/api/login`, the **policy poll**, `/api/currentUser`, `/api/logout`.
   - **Server → client** responses: **encrypt** (not just sign) the **policy-poll payload** — which pushes `nemo-permanent-password` + config — to the **client's registered device public key** (from RegisterPk, already known to hbbs). Same for **`/api/ab/get`** (the address book). The Ed25519 signature stays for integrity; add a `box_`/sealedbox layer for confidentiality so a MITM can't read the pushed password or the peer list. Only that client's key opens it.
   - Net: every control-plane byte that isn't already inside the E2E peer session is sealed to the counterpart's already-trusted key. Confidentiality no longer depends on TLS.
4. **Server→DC LDAP stays on certs for now** (per your call): `ldaps://` with a verified/pinned DC cert (see S-C). That leg terminates on the trusted server; cert-based TLS there is fine.
**Fix — defense-in-depth (still do, but no longer the sole guardian of secrets):**
5. Keep TLS on; move to a **CA-signed** cert (`--nemo-api-tls-cert/-key`) or **fingerprint-pin** the self-signed cert (reuse `fetch_server_cert`/`ca_cert`, `nemo_integration.rs:989-1055`), and turn `allow-insecure-tls-fallback` **OFF** fleet-wide. With the sealing above in place, TLS protects metadata/traffic-analysis, not the last line of defense for credentials/passwords.
**Perf:** one sealed-box per request; negligible, off the streaming path.

### S-C — LDAP DC cert-verification off-switch
**Problem.** `tls_verify=false` sets `danger_accept_invalid_certs(true)` + `danger_accept_invalid_hostnames(true)` for the DC connection (`nemo_integration.rs:1043-1045`). Defaults are safe (verify ON, `ldaps://` enforced, PEM pinning supported), but the disable path accepts **any** DC cert → MITM can harvest every login.
**Fix.** Keep verify-on as the only supported production mode; for a self-signed DC, **require** a pinned `ca_cert` PEM rather than allowing verify-off. Gate verify-off behind an explicit, loud, non-default `--insecure-ldap-i-accept-mitm` build/run flag (or remove it).
**Perf:** none.

### S-D — cross-direction nonce reuse on the shared secretbox key (primitive-level)
**Problem.** Both directions share the **same** secretbox `Key`, and each numbers its nonce from its own sequence counter starting at 1 (`tcp.rs:203-207,305,318`). So `(Key, nonce=1)` is used for **both** the first A→B and first B→A message → XSalsa20 keystream reuse + Poly1305 one-time-key reuse across directions. Hard to exploit but a real flaw.
**Fix.** Derive **per-direction subkeys** (e.g. HKDF/`crypto_kdf` with a direction label) or fold a **direction byte** into the nonce so the two directions never share a `(key, nonce)`.
**Perf:** one-time subkey derivation at handshake; zero per-message cost.

### S-E — port-forward / RDP tunnels drop the E2E layer
**Problem.** After the encrypted login, port-forward and RDP call `set_raw()` and clear the secretbox key (`port_forward.rs:190`, `connection.rs:1216`); the tunnel then relies on the inner protocol's own encryption. A plaintext-forwarded service would cross the relay in the clear.
**Fix.** Either (a) keep the secretbox layer active for tunnels (do not `set_raw`), or (b) policy-restrict tunneling to encrypted inner protocols only, and document the requirement. Tie to the per-user/device policy `enable-tunnel`.
**Perf:** keeping secretbox on a tunnel adds the same cheap symmetric layer already used everywhere else; measure, but expected negligible.

---

## Enterprise-parity checklist (AnyDesk / TeamViewer)
- [x] Peer key **pinned** + **fail-closed** on mismatch (S-A) — *no silent plaintext downgrade, ever*. (fail-closed done 2026-09-02; server-anchored pinning via `nemo-peer-keys`.)
- [~] LDAP login credential **sealed to the server's key** (DONE 2026-09-01); nonce replay guard added server-side 2026-09-03 but **AUDIT: inert** (client sends no nonce — A8). Poll **response** + address book sealed to the device key (2026-09-03), but **AUDIT: incomplete** — poll **request** not sealed (token leaks — A1), no client replay/rollback check (A2), address-book seal has no integrity (A6). TLS **CA-signed/pinned with fallback OFF** remains the load-bearing defense (S-B item 5): key plumbed but **the verifier is dead code (A4)**, so the MITM class is still open. See the AUDIT FINDINGS section.
- [x] LDAP: `ldaps://` + verified/pinned DC cert, no accept-invalid in production (S-C — off-switch now fails closed without an explicit override flag, 2026-09-03).
- [ ] Session cipher free of nonce/key reuse (S-D) — deferred (needs hbb_common proto change + lockstep rollout).
- [ ] Every channel that leaves the box is encrypted, including tunnels (S-E) — deferred (hbb_common; tunnels likely unused here).
- [ ] Independent verification: run a **hostile-client / MITM test** (bad key, unsigned policy, forged cert, downgrade attempt) and confirm each is **refused**, not degraded. (Unit tests cover the seal/verify/replay/binding logic; a live MITM/hostile-client test is still to run.)
- [ ] No regression: `e2e/` perf numbers within baseline after all of the above. (Sealing is one sealedbox per poll/ab-fetch, off the streaming path — expected free; not yet measured.)

## Definition of done
1. A connection with a mismatched/absent peer key is **refused** (not run in plaintext).
2. `/api/login` and policy polling only succeed over a **trusted or pinned** cert; a forged cert is rejected; `allow-insecure-tls-fallback` is off in the shipped config.
3. LDAP bind only proceeds against a verified/pinned DC cert.
4. A packet capture of a relayed session shows **only ciphertext** for desktop, shell, and file transfer.
5. The security changes cost **no measurable performance** (harness proof committed under `e2e/results/`).

## S-DUALKEY — per-client provisioned device keys (mutual auth + per-client sealing)

Goal (user, 2026-09-01): each client carries its own key the server pre-knows, so
the server can (a) verify a poll/connection really comes from that provisioned
client and (b) seal server→client responses to it — confidential even under a
MITM'd/self-signed TLS. Builds on the keys the fork already has (client RegisterPk
Ed25519, server Ed25519). One keypair per PARTY is enough (no separate per-direction
key); the client key MUST be unique per device.

Provisioning model chosen by the user: **manual now, preloaded later.**
- **[DONE 2026-09-01] Manual generate + import.** Server dashboard generates an
  Ed25519 keypair, pins the PUBLIC half (labelled), and shows the PRIVATE half once
  to copy. Client has an "Import device key" dialog that saves it to config
  (`nemo-device-key`). Endpoints: `POST/GET /nemo/api/device-keys`,
  `POST /nemo/api/device-keys/:id/delete`. So an operator can provision a device
  whenever, without rebuilding.
- **[TODO — FUTURE] Preloaded binaries.** Bake a unique device key into a per-client
  build at packaging time (extend `build-run-windows-client.ps1` / the locked-exe
  packaging) so a fresh install is pre-enrolled with zero manual step. Needs
  per-client build output + the server pre-pinning the matching public key.

Then (the crypto usage):
- **[DONE 2026-09-01] Signed polls + auth-mode visibility + enforcement.** Client
  signs `ClientPolicyRequest` (id + timestamp) with `nemo-device-key`; server
  verifies against the pinned public keys and records each peer's **auth mode**
  (`device-key` = own pinned private key · `default` = server public key only).
  The Peers view shows the mode per peer. A server setting **"Require provisioned
  device key"** rejects any poll not signed by a pinned key.
- **[TODO] Sealed responses.** Server seals the policy-poll RESPONSE (carries the
  managed password) and `/api/ab/get` to the client's public key (NaCl `box_`,
  Ed25519→Curve25519), so they're confidential regardless of TLS — this is the
  S-B control-plane extension in the P0 table above.

## 2026-09-02 autonomous session — S-A largely CLOSED + focused bug-hunt

### S-A now fail-CLOSED (client `cf9e6b5f4`, server `1ae8e0f`) — the plaintext-downgrade gap is closed
- **`require-encrypted-session` enforced fleet-wide** (global policy, `allow_user_override=false`); adjustable in the dashboard.
- **Client `secure_connection`:** EVERY fail-open branch (missing key, pk mismatch, id mismatch, invalid message type, parse failure) now bails under the policy instead of returning plaintext (was **H2** — only 2 of 5 branches were guarded).
- **Controlled side `create_tcp_connection`:** refuses an unencryptable incoming connection under the policy (was **H3** — a modified controller requesting `secure=false` got plaintext).
- **B — encrypted DIRECT-IP (new capability).** Direct-IP used to be *always* plaintext: the direct listener called `create_tcp_connection(secure=false)`, so the controlled side never sent its `SignedId`. Now `secure=true`, and the server pushes a **signed `{id -> Ed25519 pubkey}` map** (`nemo-peer-keys`) inside the policy; the controller verifies a direct peer's `SignedId` against it → **server-anchored** (no TOFU/MITM window), no relay, no plaintext. This delivers the pinning S-A asked for, sourced from the server instead of first-use TOFU (stronger than SSH-style TOFU).
- **Still OPEN from S-A:** a persistent per-peer TOFU store for peers NOT in the pushed map. Today such a direct peer simply **fails closed** under the policy, which is acceptable — a peer the server doesn't know can't be anchored.

### Focused bug-hunt (2026-09-02) — FIXED
- **H1 (FIXED, server `1ae8e0f`):** `record_connection_negotiation` logged the raw punch source field, **leaking the user's session token** into the server log. Now logs only the parsed source id.
- **M3 (FIXED, server `2a3ef79`):** `nemo_integration.json` (LDAP bind password) + `nemo_sessions.json` (bearer tokens) now written **0600**, like the TLS key (existing files chmod'd on deploy).
- **M4 (FIXED, server `2a3ef79`):** client-policy test literals compile again (were missing device-key fields) — server test suite green (**41 passed**).

### Focused bug-hunt (2026-09-02) — OPEN (need a design decision, not a quick patch)
- **H4 (HIGH):** `client_policy` returns **UNMASKED secrets** (`nemo-permanent-password`, proxy / address-book passwords) authenticated only by `id`+`uuid` — a weak secret that also appears in punch source fields and the admin list. Anyone with a peer's id+uuid pulls its pushed password. Proper fix = the **S-B** control-plane sealing (seal the policy RESPONSE to the client's device key) + gate secret-bearing policy behind `require_device_key`. **NOT a quick patch:** most clients have no device key today, so gating would break the working password push. Do it together with S-B / S-DUALKEY sealed responses.
- **M1 (MEDIUM):** device keys are a shared **POOL**, not bound to a peer id — any one pinned key can sign `nemo-poll:{ANY id}`, so one leaked key satisfies `require_device_key` fleet-wide. Fix = bind each generated key to a specific peer id (generate FOR a peer; verify id-match at poll). Changes the device-key UX just built → **needs the user's sign-off**.
- **M2 (MEDIUM):** the #2 blocklist gate trusts the source's **self-reported `my_id`** (a modified client spoofs it, so only honest clients are stopped). Now **cheaply fixable because B** makes the controlled side receive the source's server-anchored `SignedId` — verify the blocklist against the **anchored** id, not the claimed one. Good direct follow-up to B.
- **L-items (LOW):** login user-enumeration via distinct errors; sealed-login 5-min replay window with no nonce (overlaps S-B item 2); admin API unauthenticated when no token is set; device-key id 16-char prefix collision; `nemo-management-allow-unsigned` escape hatch ships in release builds.

## 2026-09-03 autonomous session — S-B control-plane sealing + H4 + M1 + S-C + the L-items (UNCOMMITTED)

Grounded in a fresh 6-way code recon of the exact touchpoints. All changes are **server + client `src/` only — no `message.proto`/hbb_common change** — so they need no submodule fork and no lockstep peer rollout. **Server suite green (48 lib tests, was 42); client compiles clean (`cargo check --release --features inline`).** Built + screenshot-verified on the pc2 client and **deployed to 176** (later same day).

> ⚠️ **A follow-up adversarial audit (2026-09-03, [see the AUDIT section below](#audit-findings-2026-09-03--adversarial-review-of-the-current-tree)) found that the sealing below is INCOMPLETE and several claims here are overstated.** In particular: the seal covers the policy *response* but **not the poll request** (the session `access_token` still leaks); there is **no client-side replay/rollback check** (the server-stamped `issued_ts` is dropped); the address-book seal has **no integrity** (encrypt-only, forgeable); the `nemo-api-cert-fingerprint` pin is **dead code** (stored, never enforced) so the whole MITM class stays open; and the sealed-login nonce guard is **inert** (client sends no nonce). Read the AUDIT section for the corrected picture before relying on any "DONE" line here.

### DONE — S-B / P0 mandate: seal the control plane to the device key (the top item)
- **Policy poll response is now SEALED to the client's provisioned device key** when the client proved a pinned key AND advertised `sealed:"v1"`. Sign-then-seal: the Ed25519 signature is computed over the payload and then the whole signed blob is wrapped in a NaCl `sealedbox` (Ed25519→Curve25519 via `to_curve25519_pk`) to the device key. The cleartext `payload`/`signed_payload` fields are omitted; only `sealed_payload` goes on the wire. A MITM under a forged/self-signed cert now sees **ciphertext**, not the pushed `nemo-permanent-password` or config. Client unseals then verifies the inner signature (keeps the exact S1 anti-forgery property).
  - Server: `client_policy` in `nemo_management.rs` (seal path + `seal_to_device_key`), `ClientPolicyResponse` grew `sealed_payload` (payload/signed_payload now `skip_serializing_if None`), payload grew `issued_ts`.
  - Client: `nemo_management_client.rs sync_policy`/`verified_payload` (unseal-then-verify), request advertises `sealed:"v1"`; device-key crypto moved to `common.rs` (`nemo_device_ed25519`/`nemo_device_sign`/`nemo_unseal_with_device_key`) so it is always compiled.
  - **Anti-downgrade ratchet (client):** once a sealed response has been seen, a later UNSEALED one is refused as a strip-the-seal MITM (persisted as `nemo-policy-seal-seen`).
- **Address book (`/api/ab/get`) is now SEALABLE the same way.** The client signs `nemo-ab:{id}:{ts}` (a **distinct domain** from the poll's `nemo-poll:` so signatures aren't cross-replayable) and the server seals the peer list to the device key (`sealed_data`). New Sciter bridge `nemo_ab_seal_fields`/`nemo_unseal_ab` (`ui.rs`) + `ab.tis` wiring; fails closed if unseal fails.
- **S-B item 5 (partial):** `nemo-api-cert-fingerprint` is now a managed, durably-persisted policy key on both ends (deliverable + stored for first-request use). **The rustls PinnedVerifier wiring in `configure_http_client!` is NOT built yet** — see OPEN below; today the key is plumbed but not yet enforced. Sealing already makes credential confidentiality independent of TLS, so this is defense-in-depth.

### DONE — H4: no unsealed secrets by default (opt-in strict mode)
- New setting **`strip_unsealed_secrets`** (dashboard "Only deliver secrets sealed to a device key"): when on, any policy response that can't be sealed has its secret values (`SECRET_POLICY_KEYS`) **stripped** rather than sent in plaintext. Off by default so an unprovisioned fleet keeps working; turn on once every client has a device key. This is the deployable resolution of H4 (was "needs a design decision").

### DONE — M1: device keys bound to a peer id
- `DeviceKey` grew `peer_id`; `verify_device_signature` refuses a signature whose claimed id ≠ the key's binding. Unbound (legacy) keys still authenticate any id, so existing keys keep working until re-provisioned. Dashboard "Generate device key" now takes an optional **"bind to TBFDesk ID"**; the list shows the binding. A leaked BOUND key no longer satisfies `require_device_key` fleet-wide.
- Also hardened `verify_device_key`: a **non-numeric timestamp is now rejected** (it used to silently skip the freshness check), and the poll/ab domains are separated.

### DONE — S-C: LDAP cert-verify off-switch fails closed
- `tls_verify=false` now **errors** ("pin the DC cert, or pass `--insecure-ldap-i-accept-mitm Y`") unless that loud, non-default CLI flag is set (declared in `main.rs`). `ldap_tls_verify_effective` is unit-tested. `fetch_server_cert`'s intentional accept-any (pin bootstrap) is untouched.

### DONE — the L-items
- **Admin API no longer runs tokenless:** `require_auth` **fails closed** with no token; `spawn_hbbs_api` auto-generates and logs an ephemeral token when none is set (local-dev dashboard still works — copy it from the log).
- **Sealed-login replay:** `SealedLogin` grew a `nonce`; the server remembers nonces within the freshness window and rejects duplicates (`sealed_login_guard`, unit-tested). The old **`ts==0` bypass is removed** (now rejected).
- **User enumeration:** the "user not found in directory" client-facing error is now the same "invalid username or password" as a wrong password (detail kept in the server log).
- **Device-key id prefix collision:** `device_key_id_for` extends the id past 16 chars on collision instead of silently replacing another key (unit-tested).
- **`nemo-management-allow-unsigned`:** now `#[cfg(debug_assertions)]`-gated on the client — the escape hatch is compiled OUT of release builds.

### STILL OPEN — transport & identity items that require a `message.proto`/hbb_common change (deferred deliberately)
These are blocked behind the **hbb_common fork remote** (OPEN-TODOS #9, doesn't exist yet) and/or need a **lockstep fleet rollout** (a mixed old/new pair would fail the handshake), so they were NOT started while unattended:
- **M2 (blocklist trusts self-reported `my_id`):** the clean fix adds a controller-signed `signed_id` to the `PublicKey` handshake message (proto change) so the controlled side verifies the controller against `nemo-peer-keys`. All ingredients exist (recon confirmed); it is a proto + both-handshake-sites change.
- **S-D (cross-direction nonce reuse):** needs a per-direction nonce/subkey in `tcp.rs`, negotiated via a new `SignedId`/`PublicKey` proto field to avoid breaking mixed-version sessions. Lowest severity (primitive-level, hard to exploit).
- **S-E (tunnels drop secretbox):** remove the two `set_raw()` calls and keep the framed+encrypted stream, version-gated. Low practical risk in this deployment (direct remote-desktop, tunnels likely unused).
- **S-B item 5 (cert-fingerprint pin enforcement):** implement `PinnedVerifier` (rustls) in `libs/hbb_common/src/verifier.rs` + thread through `configure_http_client!`, and short-circuit all four accept-invalid/native-tls retry ladders when a pin applies (else the fallback silently defeats the pin). The policy key is already plumbed; only the verifier is missing.
- **S-DUALKEY preloaded binaries; S-A TOFU-store residue** (both previously noted).

## AUDIT FINDINGS 2026-09-03 — adversarial review of the current tree

Read-only security audit of the whole fork (client + server + the just-landed sealing/device-key work), run as a two-phase multi-agent review: 7 finders across subsystems, then 6 refute-by-default verifiers + a malicious-management-server pass. **Every finding below was independently verified against the actual code** (file:line quoted). No code was changed. Severities are the verifiers' corrected values.

**Bottom line.** The crypto *design* is sound (sign-then-seal authenticity, correct Ed25519→Curve25519 sealing, M1 binding with no key-substitution, unsigned-policy compiled out of release, a bounded apply-policy allowlist, no dashboard XSS, no LDAP filter injection, constant-time admin-token compare, structurally sound E2E peer session, no policy-reachable RCE). The recurring weakness is **confidentiality/replay protection that leans on the management TLS channel, which is unauthenticated by design** (`allow-insecure-tls-fallback=Y` vs a self-signed cert), while the intended fix — cert-fingerprint pinning — is inert. That turns several new "defense-in-depth" controls into no-ops against exactly the MITM they target.

### A. MITM-reachable (NO signing key needed) — the priority class
| # | Sev | Finding | Location | New? |
|---|---|---|---|---|
| A1 | HIGH | **Poll request leaks the session `access_token`.** The seal covers the response, not the request; over accept-any-cert TLS a MITM reads the token from the poll body → valid session vs `/api/ab/get`, `/api/currentUser`. The P0 mandate required sealing BOTH directions; the request side was never done. | `nemo_management_client.rs:167,172,192` | gap in new work |
| A2 | HIGH | **Policy replay / rollback.** Client `ClientPolicyPayload` deserializes only `{id,policy}` and drops the server's `issued_ts`; no freshness/monotonic check on the apply path; the ratchet doesn't catch a replay (a replayed sealed blob is still "sealed"). MITM replays a captured signed/sealed policy to roll security state back (reinstate a rotated password, clear `nemo-blocked-ids`, drop `require-encrypted-session`). Signature still binds → replay of prior *valid* states only, not forgery. | `nemo_management_client.rs:103-107,158-250` | **new** |
| A3 | HIGH | **Managed secrets served in cleartext by default.** With `require_device_key` + `strip_unsealed_secrets` both OFF (defaults), the poll auth is `id + base64(machine-uuid)` only and returns `nemo-permanent-password` in cleartext JSON. The uuid is a stable machine id (locally readable, logged at `peer.rs:112`, shown in the admin peer list) — not a secret. MITM reads it outright; a local low-priv user / malicious insider can obtain uuid+id and fetch the password from anywhere with API reach. (128-bit uuid ⇒ blind guessing infeasible; real vectors are MITM + obtain-then-fetch.) | `nemo_management.rs:2618-2743, 3154-3167` | pre-existing; new flags are the fix, ship OFF |
| A4 | HIGH | **The cert-fingerprint pin is dead code.** `nemo-api-cert-fingerprint` is persisted on both ends and the comment + dashboard imply it disables the accept-any-cert fallback, but **nothing reads it**. This is the single intended defense against A1–A3/A6/A7, and it does nothing while giving operators false assurance. | `nemo_management_client.rs:43,46,325` (only sites) | new (plumbed, verifier deferred) |
| A5 | HIGH | **Direct-IP "secure" path doesn't bind to the intended peer.** `secure_connection_direct` verifies a peer's SignedId against `nemo-peer-keys` but never checks the verified id == the intended `peer_id` (the brokered `secure_connection` checks it twice). A session for peer A redirected onto ANY valid fleet member B (malicious rendezvous, LAN redirect) is accepted as secure; the controller then sends A's stored credential hash + keystrokes to B. Defeats the "server-anchored, no MITM window" guarantee the comments claim. | `client.rs:929-968` (vs `:833,872`) | pre-existing (encrypted direct-IP / feature B) |
| A6 | MEDIUM | **Sealed address book has no integrity.** `/api/ab/get` uses a bare `sealedbox` with no inner signature (unlike the sign-then-seal poll), and the device pubkey travels in cleartext in every request. Anyone who sees it can forge a peer list sealed to it; client unseals + `JSON.parse` with no signature check → address-book poisoning (operator connects to an attacker host under a trusted name). Confidentiality holds, integrity absent. | `nemo_management.rs:1806-1811`; `ab.tis getAb` | **new** |
| A7 | MEDIUM | **Ratchet first-contact gap.** The ratchet engages only after the first sealed response, so a MITM strips the device-key fields from the first poll → with `strip_unsealed_secrets` OFF (default) the server returns the pushed secrets in signed plaintext, which the MITM reads. | `nemo_management_client.rs:179-219` | **new** |
| A8 | MEDIUM | **Sealed-login replay guard is inert.** The server nonce guard never engages because `nemo_seal_login` still sends `{username,password,ts}` with no nonce; the empty-nonce branch logs a warning and ACCEPTS. A captured sealed `/api/login` blob replays within ~300s for a fresh session token. | `common.rs:2220`; `nemo_management.rs:1100-1125` | new (incomplete) |

### B. Robustness / availability (introduced by the recent work)
- **B1 (MEDIUM) — anti-downgrade ratchet can brick policy sync.** Once `nemo-policy-seal-seen=Y` is persisted, any later UNSEALED response makes the client refuse all policy application forever, with no server-side recovery. Deleting/rotating device keys (or a client losing its local key) silently bricks it, potentially fleet-wide. `nemo_management_client.rs:125-133,209-219`.
- **B2 (LOW, latent) — `device_key_id_for` panics** on a pubkey with zero alphanumerics (slice OOB); not reachable via the current admin-only caller, but a regression from the old non-panicking version. `nemo_integration.rs:665-679`.

### C. Server-side / deployment
- **C1 (MEDIUM) — `restrict_file` is a no-op on Windows, and Windows is the deployment target.** The M3 0600 hardening for `nemo_integration.json` (LDAP bind password) and `nemo_sessions.json` (bearer tokens) only runs under `cfg(unix)`; on Windows those files inherit working-dir ACLs → any local user/process reading the server dir gets the domain service-account password + active session tokens. `nemo_integration.rs:314-324`.
- **C2 (MEDIUM/LOW) — unbounded maps + no login rate limit.** `PEER_HOSTNAMES` uncapped and rewrites its whole JSON per new id (O(n²) disk write-amplification) while peer-stats IS capped; `PEER_AUTH_MODES` uncapped; `SEEN_LOGIN_NONCES` growable by an unauthenticated attacker with O(n) retain under a global lock; and there is **no global/per-IP login rate limit** (per-username backoff runs after the bind and only delays the response → password-spraying via username rotation + parallel attempts is unthrottled). `nemo_management.rs:670-692,285-295,1091-1125,1144-1219`.
- **C3 (LOW) — auth hygiene.** LDAP service-account mode has a username-enumeration timing side-channel (extra bind for existing users); the allowlist-rejection message distinguishes valid-but-unauthorized from invalid credentials (credential-validity oracle); admin/session tokens cross the network in cleartext when LDAP is disabled (TLS auto-enable is gated only on LDAP). `nemo_integration.rs:1620-1654`; `nemo_management.rs:1173-1178,737-742`.

### D. Compromised-but-trusted management server (the server holds the Ed25519 key = the declared trust root)
Largely by design (the server controls the fleet), but two effects **outlive the compromise window** and are worth noting: a pushed policy can durably plant `api-server=attacker` and `allow-insecure-tls-fallback=Y` (persist across restart and even after `nemo-management-enabled` is turned off), and `nemo-permanent-password` is applied unconditionally (ignoring `allow_user_override`) into the **system/service** config via IPC — the highest-value takeover primitive. `nemo_management_client.rs:321-332,333,411-423`.

### E. Known-deferred — confirmed still open (not new)
S-A (plaintext-downgrade fallback still ships because `nemo-require-encrypted-session` defaults OFF), S-D (cross-direction secretbox nonce reuse — keystream/MAC reuse confirmed), S-E (port-forward/RDP tunnels drop the secretbox), M2 (blocklist trusts self-reported `my_id`; the in-code comment overstates the guarantee), and `Encrypt::dec()` passing frames ≤1 byte through unauthenticated.

### Verified SOLID (checked, not assumed)
Sign-then-seal policy authenticity; M1 device-key binding (no key-substitution, enforced on poll AND address book); unsigned-policy bypass **not** MITM-reachable (release-gated; empty-key self-unlock neither works nor survives restart); apply-policy allowlist bounds the server to known keys; Ed25519 verification not bypassable; dashboard output uniformly `escapeHtml`'d; LDAP filters RFC-4515 escaped; admin API fails closed with constant-time compare on every handler; E2E peer session arithmetic sound (fresh ephemeral keys / PFS); no policy-reachable RCE-via-update (update URL hardcoded, not policy-controlled).

### FIXES IMPLEMENTED 2026-09-03 (UNCOMMITTED, NOT yet deployed/live-verified)
Follow-up implementation pass after the audit. **Server suite green (49 tests); client compiles clean + client suite green (70 tests).** Not yet built-to-live or deployed (awaiting go-ahead).
- **A4 — cert-fingerprint pin WIRED (the big one).** New `PinnedVerifier` (rustls, SHA-256 of the leaf DER) + `client_config_pinned` in `hbb_common/src/verifier.rs`; `create_http_client_async_pinned` in `hbbs_http/http_client.rs`; `nemo_pin_for_url`/`parse_fingerprint_hex`/`pinned_request` in `common.rs`. When `nemo-api-cert-fingerprint` is set and the URL targets the api/management host, the poll + ab + login use the pinning client and the accept-invalid/native-tls retry ladder AND the raw-TCP fallback are **skipped** (so the fallback can't defeat the pin). Opt-in (empty default = unchanged behavior). Deliver the pin fleet-wide via the managed policy key (already plumbed) — the login gate shows the fingerprint to copy.
- **A5 — direct-connect identity binding.** `secure_connection_direct` now takes `peer_id` and refuses a session whose proven id != the requested id (mirrors the brokered path). `client.rs`.
- **A2 — replay/rollback check.** Client deserializes `issued_ts` and enforces a monotonic high-water mark (`nemo-policy-issued-ts`) + absolute staleness window; rejects rolled-back/replayed policies. `nemo_management_client.rs` (unit-tested).
- **A6 — address book sign-then-seal.** Server signs the AB JSON before sealing; client `nemo_open_sealed_signed` verifies the inner signature after unsealing. `nemo_management.rs` + `common.rs` + `ui.rs`.
- **A1 — poll request token sealed.** The `access_token` is sealed to the mgmt key (`sealed_token`, reusing the pinned Ed25519 key → Curve25519, no round-trip); server `resolve_access_token` opens it. `common.rs` + both `nemo_management_client.rs`/`nemo_management.rs` (unit-tested).
- **A8 — client login nonce.** `nemo_seal_login` now emits a random nonce so the server's replay guard actually engages. `common.rs`.
- **B1 — ratchet no longer bricks.** The seal ratchet is enforced only while the client still holds a device key (a client that lost its key accepts plaintext and clears the ratchet); a clear recovery message names the config key otherwise. `nemo_management_client.rs`.
- **B2 — `device_key_id_for` panic guard.** Empty-alnum key returns `""` instead of panicking. `nemo_integration.rs` (unit-tested).
- **C1 — Windows file ACLs.** `restrict_file` now sets an `icacls` ACL (SYSTEM + Administrators + running user) on Windows instead of a no-op. (Server runs on Linux/176 where 0600 already applied; this is defensive for a Windows host.) `nemo_integration.rs`.
- **C2 (partial) — bounded DoS maps.** `PEER_HOSTNAMES` (+ 256-char hostname cap), `PEER_AUTH_MODES`, and `SEEN_LOGIN_NONCES` are now size-capped with eviction. `nemo_management.rs`.

**STILL OPEN after this pass:** A3/A7 close by *policy* (turn ON `strip_unsealed_secrets` + `require_device_key` once every client is provisioned — operational, no code); the C2 **login rate-limit** (password-spraying) was left to the operator/AD-lockout backstop — a per-IP limit needs `ConnectInfo` plumbing and a global throttle has a DoS trade-off; the ratchet **scenario-2 brick** (admin deletes a client's pinned key while the client keeps its local key) still needs a manual recovery (re-pin, or clear `nemo-policy-seal-seen`); an optional per-client "Pin this certificate" button on the login gate (A4 is usable now via managed policy); and the transport tier (S-D/S-E/M2) still needs the hbb_common proto work.

### Highest-leverage fixes (recommended order) — original audit recommendation, now mostly DONE above
1. **Wire the cert-fingerprint pin** (A4) — or ship a trusted CA cert with the insecure fallback OFF. Collapses the entire MITM class (A1, A2, A3, A6, A7). ✅ DONE (enforcement; deliver the pin via policy).
2. **Seal the poll request's `access_token`** (A1) **and add the client-side `issued_ts` freshness/anti-rollback check** (A2). Server already stamps `issued_ts`; no server change needed for the freshness half.
3. **Add `id == peer_id` to `secure_connection_direct`** (A5), and **sign-then-seal the address book** (A6, mirror the poll).
4. **Fix `restrict_file` on Windows** (C1) — cheap, high value, independent of the crypto work.
5. Turn ON `strip_unsealed_secrets` + `require_device_key` once every client is provisioned (closes A3/A7 by policy today); add a client login **nonce** (A8); cap the DoS maps + add login rate limiting (C2); provide a server-driven un-ratchet (B1).

## Cross-references
- Existing roadmap security items S1–S10 in `.claude/plans/analyze-this-repository-and-fizzy-parrot.md` (this doc supersedes/expands the transport-security portion).
- Prior stopgap noted in `TODO.md` (⭐ CA-trusted cert) → folded into **S-B**.
- Speed/codec analysis (incl. why encryption costs no performance) → `SPEED-AND-CODEC-RESEARCH.md`.

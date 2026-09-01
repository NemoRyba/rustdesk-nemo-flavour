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
- [ ] Peer key **pinned** + **fail-closed** on mismatch (S-A) — *no silent plaintext downgrade, ever*.
- [ ] LDAP login credential **sealed to the server's key** (TLS-independent confidentiality) + replay guard; TLS also **CA-signed/pinned** with fallback OFF (S-B).
- [ ] LDAP: `ldaps://` + verified/pinned DC cert, no accept-invalid in production (S-C).
- [ ] Session cipher free of nonce/key reuse (S-D).
- [ ] Every channel that leaves the box is encrypted, including tunnels (S-E).
- [ ] Independent verification: run a **hostile-client / MITM test** (bad key, unsigned policy, forged cert, downgrade attempt) and confirm each is **refused**, not degraded.
- [ ] No regression: `e2e/` perf numbers within baseline after all of the above.

## Definition of done
1. A connection with a mismatched/absent peer key is **refused** (not run in plaintext).
2. `/api/login` and policy polling only succeed over a **trusted or pinned** cert; a forged cert is rejected; `allow-insecure-tls-fallback` is off in the shipped config.
3. LDAP bind only proceeds against a verified/pinned DC cert.
4. A packet capture of a relayed session shows **only ciphertext** for desktop, shell, and file transfer.
5. The security changes cost **no measurable performance** (harness proof committed under `e2e/results/`).

## Cross-references
- Existing roadmap security items S1–S10 in `.claude/plans/analyze-this-repository-and-fizzy-parrot.md` (this doc supersedes/expands the transport-security portion).
- Prior stopgap noted in `TODO.md` (⭐ CA-trusted cert) → folded into **S-B**.

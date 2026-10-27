# Security verification — pre-production (2026-10-19)

**Threat model (operator):** users do NOT leak their logins or keys. The attack surface is
the **network** (internet and the company subnet) and the **computers** (a machine the
attacker controls, or is on the same LAN as). So: an active man in the middle on the wire,
and an attacker with a foothold on a LAN/host — but not stolen credentials.

This doc has two parts: a code-level trust-boundary review (done), and the live adversarial
test plan (to run in the lab).

## Penetration test result (concluded 2026-10-20)

The live adversarial tests were run as an authorized, lab-only **assumed-breach** engagement
(full package + per-scenario results in [`pentest/`](pentest/FINDINGS.md)). **Outcome: no BREAK** —
every property in Part 1 held under attack: passive capture; MITM with a rogue cert, pin present and
cleared; policy replay/rollback; direct-session control-ticket forgery; knock/SPA replay/forge/scan;
rendezvous/relay; the update path; and management-API auth. The exposures in "Residual risks" below
are confirmed as **residuals, not breaks**. **Hardening added since:** **C1** (pre-gate per-source
rate limit on the unauthenticated mgmt-API routes), **C3** (`require_auth` before body parse on every
`/nemo/api/*` admin route), **C4** (operator **Security panel** in `/nemo/admin`: metrics, anomaly
log, per-entry Unblock/Reset/Clear). See `pentest/08-IMPROVEMENTS.md`; **C2** and **C5–C9** remain.

## Part 1 — trust-boundary review (from the code)

### Management API (policy poll, login, address book, update) — the channel that carries secrets

| Property | Mechanism | Verdict |
|---|---|---|
| Server is authenticated | Cert **pin** (`nemo-api-cert-fingerprint`, SHA-256 of the leaf), set from the setup bundle at provisioning. The pinned verifier now also checks the handshake signature (fixed this session, hbb_common 69260a8 + test) — before, a MITM with a *copy* of the public cert was accepted. | **Strong** once provisioned |
| Policy cannot be forged | Every policy response is Ed25519-signed by the management key, which the client pins. Unsigned policy is refused; the dev escape hatch is compiled out of release builds. | **Strong** |
| Login / session token not readable on the wire | The poll body is sealed (NaCl sealedbox) to the management key. With a key configured, sealing is mandatory: a failed seal sends **nothing** (no plaintext fallback). | **Strong** |
| Pushed secrets (password, peer keys, knock keys) not readable | The policy *response* is sealed to the client's device key (sign-then-seal). | **Strong** |
| No TLS-strip downgrade | Anti-downgrade ratchet: once a sealed response is seen, a later unsealed one is refused (while a device key is held). | **Strong** |
| No replay / rollback of old policy | Anti-replay: `issued_ts` high-water mark; an older authentic policy is refused. Session revocation is idempotent. | **Strong** |
| Address book not readable | `nemo-sealed-request`: the whole AB request and response can be sealed. | **Strong when enabled** (see residuals) |
| Server not reachable in the clear | hbbs refuses to serve the API over plaintext HTTP on a routable address; anything not loopback gets TLS. | **Strong** |
| Server can force the fail-closed modes | `require_sealed_login`, `require_sealed_request`, `require-device-key` are server-side switches. | present, **off by default** |

### Rendezvous / relay plane
- Device-key handshake authenticates a peer; keys are pinned server-side; a claim needs
  operator approval (M1-CLAIM). Controller identity rides a typed field (NemoSource) and is
  stripped from the relayed frame.
- `nemo-require-secure-rendezvous=Y` refuses the plaintext UDP fallback.

### Direct sessions (verified in the lab this session — LAB-VERIFICATION-2026-10-19)
- The **control ticket** is signed by the server, bound to the controller's device key and
  to this connection's challenge (`nemo-ctl:<target>:<challenge>`), so a copied ticket is
  useless on another machine and a recorded login useless on another connection. Target
  verifies against the pinned management key; epoch revokes stale tickets.
- The **knock** (fwknop SPA) is replay-protected and HMAC-authenticated; wrong keys and
  replays are refused (verified against a real fwknopd, OPENWRT-FWKNOP-LAB.md).
- Direct-IP peers are encrypted with a **server-anchored key** from the signed `nemo-peer-keys`
  map, so a direct session needs no rendezvous and still can't be MITM'd without the mgmt key.

### Update path
- Signed manifest (management key) + sha256 of the file + **pinned** download (fixed this
  session: the installer now uses the same pin as the poll, no accept-any fallback).
- Residual: the signing key is the server's management key — see **Residual risks**.

## Residual risks (under this threat model)

1. **TLS authentication rests on the cert pin.** A provisioned client has the pin from its
   setup bundle, so from the first poll a MITM cannot intercept. But if a client has **no**
   pin (not yet provisioned, or the option cleared), TLS falls back to accepting a
   self-signed cert — a MITM could then read anything **not** sealed (hostnames, and the
   address book if `nemo-sealed-request` is off) and could block traffic. It still cannot
   forge policy (signed) or read the login/token (sealed to the mgmt key). **Hardening:**
   for production, turn ON `require_sealed_login`, `require_sealed_request` and
   `require-device-key`, and consider a "require pinned TLS" switch so a cleared pin fails
   closed instead of accepting any cert.
2. **The update signing key is the server's management key.** Whoever takes over the server
   can publish any installer, which clients install with system rights. Mitigation plan:
   OPEN-TODOS 35 — a separate release-signing key kept off the server.
3. **An attacker on a client machine.** A local non-admin or a LAN peer: what config,
   secrets and ports are reachable? To be tested live (part 2). Managed secrets are marked
   `<managed-secret>` in readbacks; the device private key and session token live in the
   per-user config — their file permissions and reachability need checking on each OS.
4. **Metadata exposure when sealing is off.** Even fully MITM-proof against credential
   theft, an unsealed AB fetch reveals which machines exist (ids, aliases, hostnames). Turn
   sealing on for production.

## Production hardening checklist (switches to set before go-live)

- [ ] `require-device-key = Y` (global) — only provisioned machines poll.
- [ ] `require_sealed_login = Y`, `require_sealed_request = Y` — fail closed on unsealed.
- [ ] `nemo-require-secure-rendezvous = Y` — no plaintext rendezvous fallback.
- [ ] `nemo-require-control-ticket = Y` — **only after every client is 1.4.14+** (TODO 30).
- [ ] `allow-insecure-tls-fallback = N` once a CA-signed (or pinned) cert is in place.
- [ ] A CA-signed API cert, or confirm the pin is distributed to every client.
- [ ] Edge: the knock/forward hardening in ROUTER-KNOCK-RUNBOOK.md; WAN input = DROP.

## Part 2 — live adversarial tests (to run in the lab, NOT production)

All against our own lab (host hbbs, the containers/VM, the OpenWrt router). Tools already
present: tcpdump, wireshark group. Add as needed: a transparent TLS proxy (mitmproxy),
ARP/DNS spoof (ettercap/bettercap or scapy), optionally a Kali VM for a curated toolset.

1. **Passive capture** of a full poll/login/AB/update exchange — confirm no cleartext
   credential, token, password or key is on the wire (only ciphertext + the signed policy).
2. **Active MITM, no pin** — stand up a rogue TLS endpoint, redirect a client to it, confirm:
   policy forgery is refused (bad signature), login/token stay sealed (unreadable), a
   stripped (unsealed) response is refused by the ratchet.
3. **Active MITM, with pin** — confirm the TLS handshake itself is refused (the fix this
   session; a non-pinned verifier would have accepted a copied cert).
4. **Replay** — capture an authentic older policy / a login / a knock and replay it; confirm
   refusal (issued_ts high-water, HMAC/replay cache).
5. **Direct-session attacker** — present a stolen control ticket from another machine / over
   another challenge; confirm refusal. Knock spoofing from a wrong source.
6. **Endpoint foothold** — as a non-admin user on a client, what config/secrets/ports are
   readable or writable; can a LAN peer reach the direct port without a knock.
7. **Update path** — a MITM swaps the installer bytes; confirm the sha256 check rejects it;
   with the pin, confirm the download TLS is refused.

Findings from each will be appended here with the capture evidence.

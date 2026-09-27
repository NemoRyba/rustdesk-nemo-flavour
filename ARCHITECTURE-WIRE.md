# TBFDesk — what talks to what, and what protects it

Verified against the code, not against the design documents. Every claim here was checked
at the call site; where something is conditional the condition is stated.

Read with `DECISIONS-2026-09-21.md` (why things are the way they are) and `DEPLOY.md`
(how to run it).

---

## Topology

Three roles. "Client A" and "client B" are **roles taken per session**, not properties of a
machine: A is whoever starts the call and watches, B is whoever answers and is watched. In
this deployment A is always a technician out on the internet and B is always a CAD
workstation on site, but nothing in the software enforces that.

```
        INTERNET                    │  SITE
                                    │
        CLIENT A                    │        SERVER              CLIENT B
      the controller                │   one host, two daemons   the controlled
   ┌──────────────┐                 │   ┌──────────────────┐      ┌───────────────┐
   │  technician  │                 │   │  hbbs  rendezvous│      │  workstation  │
   │   (laptop)   │                 │   │  hbbr  relay     │      │   × 15 (CAD)  │
   └──────┬───────┘                 │   └─────────┬────────┘      └───────┬───────┘
          │                         │             │                       │
          │  ─────── L1 ────────────┼────────────►│◄────────── L1 ────────┤
          │  rendezvous / signalling│             │                       │
          │                         │             │                       │
          │  ─────── L7 ────────────┼────────────►│                       │
          │  management API         │             │                       │
          │                         │             │                       │
          │  ═══════ L5 ════════════┼═════════════╪═══════════════════════╡
          │  relayed session (hbbr just pumps bytes)                      │
          │                         │             │                       │
          │                         │             │   ═══ L4 ═══          │
          │                         │             │   direct P2P          │
          │                         │             │   (same subnet only   │
          │                         │             │    at defaults)       │
```

| role | what it is | what it holds | who starts the connection |
|---|---|---|---|
| **client A** | the controller — the viewer window, decodes video, sends keyboard and mouse. Picks quality, codec and frame rate; those live in *its* per-peer config | its device key, its identity keypair, the user's session token | always A. Nothing ever dials in to it |
| **server** | hbbs introduces clients and enforces who may call whom; hbbr carries bytes when the two cannot reach each other. One host, ports 21115–21117 plus 21120 for the management API (21118/21119 listen but refuse) | the Ed25519 key both clients pin, the device-key registry, the LDAP bind | never — it only answers, and pushes down connections clients already hold |
| **client B** | the controlled machine — captures and encodes the screen, applies input, checks the password. One encoder serves every viewer | its device key, its identity keypair, the permanent password | dials **out** to the server and holds that connection open. No inbound port, no port forward |

The server is trusted to *introduce*, not to *listen*: it never holds a key that opens a
session. See L4 and L5.

### The four cases

The session is **always** started by a technician on the internet toward a workstation on
site. That gives four things worth walking separately: each side proving itself to the
server, and the two ways the session can then reach the workstation.

| # | case | legs | status |
|---|---|---|---|
| 1 | a **workstation** verifies itself to the server | L1, then L7 for its policy | shipped |
| 2 | a **technician** verifies themselves to the server | L1, then L7 for LDAP login | shipped |
| 3 | technician → workstation **relayed** | L1 → (failed L4) → L5 | shipped, and what happens today |
| 4 | technician → workstation **direct** | L1 → L4 | **not shipped** — see below |

**Cases 1 and 2 are the same handshake.** Not merely similar: `secure_tcp` →
`nemo_rendezvous_key_exchange` → `NemoClientAuth` is one code path, hbbs runs one set of
checks, and a packet capture of the handshake could not tell the two apart. Two things
differ, and neither is the verification:

- **Lifetime.** The workstation holds one connection open for its whole life and
  re-announces itself every 15 s (`REG_INTERVAL`, `rendezvous_mediator.rs`). The technician
  opens a fresh socket per connect attempt, sends `PunchHoleRequest` and drops it
  (`client.rs:536`). Note that a technician running the client normally — without
  `--no-server` — *also* keeps a registered connection, so one machine does both.
- **The four gates are opt-in from the caller's side.** `controller_policy_rejection_from_field`
  (`nemo_management.rs:3116`) starts with `controller_source_identity(source_field)?` — the `?`
  means an absent or malformed source marker returns "no rejection", i.e. **pass**. The
  identity that drives every controller-side ACL is carried in an unsigned marker, not bound
  to the device key that was just proven.
- **Layer 2.** Only the technician logs in against LDAP and carries a session token. An
  unattended workstation authenticates to the management API with its **device key
  signature** instead (`nemo_management_client.rs`): no user, no password, no directory.
  Layer 2 is also **off at shipped defaults** — `require_login` is `false`
  (`nemo_integration.rs:271`), so a logged-out technician whose machine holds a valid device
  key can still punch. Layer 1 is on by default; Layer 2 is not.
- **Where the binding is re-checked.** Both prove the device key's bound peer id at the
  handshake. The workstation has it checked again when `RegisterPk`/`RegisterPeer` announce
  that id; the punch and relay frames carry no equivalent cross-check.
- **hbbs requires the technician to be registered too.** `controller_policy_rejection`
  (`nemo_management.rs:3071`) refuses the punch unless the caller is in the registered-peer
  table with a matching uuid, so a technician is a fully registered peer that happens to be
  asking for someone.

Worth correcting one natural assumption about case 3, in both directions. Run **bare `hbbs`
with no flags** and it does *not* reach for the relay: `--mask` is unset, so `is_lan` is
always false, nothing is forced, hbbs pushes a `PunchHole`, the punch fails and the *client*
falls back to `RequestRelay`. But **the committed systemd unit sets `--mask`**
(`systemd/rustdesk-hbbs-nemo.service:35`), which puts the workstation inside and the
technician outside — and `peer_is_lan ^ is_lan` then forces the relay outright
(`rendezvous_server.rs:1280`), rewriting `nat_type` to `SYMMETRIC` so the client does not
even try. **In the deployment, no direct attempt is ever made.**

**Case 4 is blocked by three independent things**, and fixing any one alone changes nothing:

1. `--mask` in the shipped unit forces the relay, so no direct attempt is made at all.
2. `PunchHoleResponse.socket_addr` is the address hbbs *observes*. hbbs is **on site**, so
   it observes `192.168.x.y` — meaningless from the internet (`rendezvous_server.rs:1094`).
   This is structural; no flag fixes it.
3. UDP punching is dead-ended inside hbbs: the UDP `PunchHoleSent` arm is a deliberate
   no-op (`rendezvous_server.rs:575`) and `is_udp` is never set on the response, so the
   client drops its UDP socket every time. Not a default that can be flipped.

Which leaves **exactly one lever: IPv6** — and it is better than it looks, because over v6
there is no translation, so reason 2 *evaporates* rather than being worked around. Better
still, it survives reason 1: `start_ipv6` is gated on `use_ws || is_proxy || force_relay`
and runs at `rendezvous_mediator.rs:666`, while the `SYMMETRIC`/relay check is only at
`:675` — so the v6 attempt still happens with `--mask` in place. What
it would take is in `vm/shots/DESIGN-direct-path-analysis.md` §7; the headline is that
direct buys resilience and server load, **not** latency, because the relay is on site and
the thin uplink is crossed once either way.

`───` signalling · `═══` session payload

---

## The legs

### L1 · client ↔ hbbs — rendezvous / signalling
```
   TCP 21116        framing: length-prefixed protobuf (BytesCodec)

   hbbs ──► KeyExchange{ Ed25519_sign(ephemeral_X25519_pub, server_key) }   ← plaintext,
                                                                              public by design
   client ─► NemoClientAuth{
                 client_box_pk,                     X25519 ephemeral
                 sealed_key = box_seal(K‖0x01),     K = 32 random bytes, CLIENT-generated
                 device_pub,                        the machine's pinned Ed25519 pubkey
                 peer_id,
                 sig = Ed25519( "tbfdesk-rzv-dev-v1"
                                ‖ server_eph_pk ‖ client_box_pk
                                ‖ sealed_key ‖ peer_id )
             }
   ── every frame from here on ──►  XSalsa20-Poly1305 under K
   (since 2026-09-22 the NemoClientAuth above travels inside NemoSealedAuth, sealed to the
    server's pinned key before it leaves the client — task #23)
```
| | |
|---|---|
| **cipher** | XSalsa20-Poly1305 (NaCl secretbox) |
| **key** | 32 random bytes chosen by the **client**, sealed to the server's per-connection ephemeral |
| **nonce** | LE64 counter in bytes 0–7, **direction byte at 8** (initiator 0, responder 1) |
| **server proves** | its Ed25519 signature over the ephemeral, verified against the pinned `key` |
| **client proves** | a **pinned device key**, bound to the peer id it registers as |
| **replay** | the signature covers the server's per-connection ephemeral — a captured proof is useless elsewhere. No clock involved |
| **carries** | peer id, machine uuid, peer public key, target id, licence key, session token, NAT type, **internal LAN addresses** |
| **status** | **ENCRYPTED**, both ends fail closed |

A client with no device key falls back to a plain `KeyExchange` and hbbs refuses it when
`require_device_key` is on — which is the default.

### L2 · client → hbbs over UDP
```
   UDP 21116        NO handshake exists for a datagram socket
```
**REFUSED by default** (`--udp-registration=N`, client `disable-udp=Y`). Still live and
unauthenticated on that port regardless of the flag: the `SoftwareUpdate` arm (answers any
datagram with `software_url`) and `ConfigureUpdate` (loopback source only).

### L3 · hbbs → client — pushes
```
   PunchHole · FetchLocalAddr · forwarded RequestRelay · PunchHoleResponse · RelayResponse
```
Ride the peer's **own** L1 connection and are sealed with that connection's key. Falls back
to a **plaintext UDP datagram** only for a peer that registered over UDP — unreachable at
defaults.

### L4 · client ↔ client — the session itself
```
   TCP on the punched port pair, or KCP-over-UDP, or IPv6

   OFF by default here: both punch options force to N for a self-hosted rendezvous
   server, so in practice this leg is reached only between two machines on the same
   subnet, via FetchLocalAddr/LocalAddr rather than a punch.

   controlled ──► SignedId{ Ed25519_sign( IdPk{ id, eph_X25519_pub },
                                          own_device_Ed25519 ) }
   controller  :  verifies with the peer pubkey hbbs signed and handed over
                  in PunchHoleResponse.pk  →  two-level Ed25519 chain
   controller ──► PublicKey{ asymmetric_value, symmetric_value = box_seal(K‖0x01) }
   ── every frame from here on ──►  XSalsa20-Poly1305 under K
```
| | |
|---|---|
| **covers** | video, audio, cursor, clipboard, file transfer, keyboard/mouse, login |
| **trust chain** | hbbs signs the peer's identity key → the peer signs its own ephemeral |
| **password** | never crosses the wire — `SHA256(SHA256(pw‖salt)‖challenge)`, and that is inside the cipher too |
| **status** | **CONDITIONAL** — see the downgrade below |

### L5 · client ↔ client **through hbbr** — relayed session
```
   TCP 21117

   ── control frame ─────────────────────────────────────────────────────
   hbbr ──► KeyExchange{ Ed25519_sign(ephemeral, hbbr's key) }
   client ─► sealed K                       ← separate key, hbbr-specific
   client ─► RequestRelay{ licence_key, id, uuid }        encrypted
   both ──► clear_key()                     ← cipher dropped, framing kept

   ── payload ───────────────────────────────────────────────────────────
   client A ══[ L4 ciphertext ]══► hbbr ══[ same bytes ]══► client B
```
**Exactly one encryption layer, and it is the end-to-end one.** hbbr drops its own cipher
the instant it has read the control frame, then becomes a byte pump. It sees XSalsa20
ciphertext and **cannot read video, audio, clipboard or files**. No double encryption — so
relaying costs bandwidth and a hop, not CPU.

### L6 · direct-IP / `host:port`
```
   TCP — NO handshake, NO cipher, NO authentication
```
The controller returns the raw socket and never calls `secure_connection`. Currently
**non-functional** as well as plaintext (the controlled side waits for a `PublicKey` that
never arrives), and off by default (`direct-server`). It is still the one path where
"fast" and "encrypted" diverge.

### L7 · client ↔ management API
```
   HTTPS 21120        TWO layers

   ┌─ TLS ────────────────────────────────────────────────────┐
   │  ┌─ sealed envelope (NaCl sealedbox to the pinned        │
   │  │   management Ed25519 key, ±300 s, nonce cache)  ─┐    │
   │  │      login · policy poll                          │   │
   │  └───────────────────────────────────────────────────┘   │
   │     address book               ← TLS only by default     │
   └──────────────────────────────────────────────────────────┘
```
Login and the policy poll survive a TLS-stripping MITM. The address book does not: it
carries the session token as a plain bearer value unless `nemo-sealed-request=v1`.
The upstream HTTP heartbeat (`POST /api/heartbeat`, `/api/sysinfo`) is **gone** from the
client: it was unauthenticated, this fork never served the routes, and its `strategy`
reply wrote arbitrary persisted config keys straight past `POLICY_DENIED_KEYS`.
And TLS here **authenticates nothing** by default — the client falls back to accepting an
invalid certificate and caches that choice, unless `nemo-api-cert-fingerprint` is pinned.

### L8 · hbbs → LDAP / AD
`ldaps://` enforced; plaintext `ldap://` is refused outright. Certificate verification is
on unless someone passes `--insecure-ldap-i-accept-mitm`.

---

## Key inventory

| key | lives | protects | if lost |
|---|---|---|---|
| server `id_ed25519` | server, shared by hbbs **and** hbbr | signs every rendezvous and relay offer; signs peer identity keys and update manifests | the whole fleet fails closed |
| device key (Ed25519) | each client, `nemo-device-key` | Layer 1 — proves the machine is provisioned, at the transport **and** the API | that machine cannot connect; no CLI recovery path by design |
| peer key pair | each client | its own identity, signed by hbbs for peers | re-registers, peers see a key change |
| permanent password | controlled machine | session login | — (never on the wire) |
| session token | controller, `LocalConfig` | per-user ACL and require-login | bearer credential — replayable if leaked |
| admin API token | server argv/env + the admin browser | the whole management API, incl. `require_device_key` | full fleet control |
| management public key | pushed to clients | anchors the sealed envelope and signed policy | — |

---

## Before the encryption question: who is allowed to ask?

Three findings from the September 22 sweep are not about ciphers at all, and two of them
outrank everything in the next section.

1. **The controller policy gates are skippable by omission.**
   `controller_policy_rejection_from_field` (`nemo_management.rs:3116`) opens with
   `controller_source_identity(source_field)?` — and the `?` returns `None`, which the
   caller reads as *no rejection*. An absent or malformed source marker skips all four
   gates. Worse, the identity those gates key off rides in that marker, unsigned, and is
   never tied back to the device key proven moments earlier: hbbs binds `authed.peer_id`
   only in the `RegisterPk`/`RegisterPeer` arms, never on `PunchHoleRequest` or
   `RequestRelay`.

2. **An unbound device key authenticates any machine.** A key minted with a blank
   `peer_id` falls through to the accept arm at both enforcement points
   (`rendezvous_server.rs:2058`, `nemo_management.rs:2466`). That is the documented
   meaning of a blank binding — and the admin dashboard's peer-id box is optional free
   text, so one empty field mints a fleet-wide skeleton key.

3. **The relay checks nothing but the shared server key.** `relay_server.rs:471` accepts
   only a plain `KeyExchange`; there is no device proof on 21117. Layer 1 governs who may
   *ask* hbbs for a relay, not who may connect to hbbr. And hbbr holds the same Ed25519
   signing key as hbbs by design, and sees the end-to-end handshake frames in the clear
   once it drops its own cipher.

---

## So: is everything encrypted?

**No — but the gaps are now specific and named rather than structural.** Encrypted
unconditionally: rendezvous signalling, server pushes, the relay control frame, the relayed
payload, LDAP, and the management API's login and policy poll. What is left:

0. ~~The rendezvous identifies every machine in the clear.~~ **Fixed 2026-09-22 (task #23):**
   the client now sends the whole `NemoClientAuth` inside a `NemoSealedAuth` envelope (union
   tag 30) sealed to the server's pinned key, and the server opens it before the handshake
   match. The session key inside stays sealed to the per-connection ephemeral, so forward
   secrecy and the replay property are unchanged; only the identity fields gained
   confidentiality.

1. ~~Port-forward / RDP tunnels are plaintext, always.~~ **Fixed 2026-09-27:** both ends
   used to call `set_raw()` after login, dropping the cipher and the framing. They now keep
   the stream framed and keyed and send tunnel chunks with `send_raw()` (sealed per chunk).
   Both ends must run the fixed client.
2. **Direct-IP-by-address sessions are plaintext.** `Client::_start` returns a bare TCP
   stream for an `<ip>` or `<host>:<port>` peer and never calls `secure_connection`, so
   nothing anchors it — `nemo-peer-keys` is keyed by id, and an address has no id.
   `nemo-require-encrypted-session` (now ON by default) does not rescue this path, it
   refuses it: the controlled side drops the connection because no key exchange
   completed. `direct-server` is off by default, so this is latent.
3. **LAN discovery is on by default** and broadcasts id, hostname, **the active username**,
   platform and MAC to the whole subnet.
4. **Public STUN** queries go to Google/Cloudflare/Nextcloud on every connect attempt while
   `enable-udp-punch` is on — which is its default — leaking that this site exists.
5. **Port 21115 answers anyone**: `OnlineRequest` lets an unauthenticated caller enumerate
   which TBFDesk ids are online.
6. **The UDP `SoftwareUpdate` arm** answers any datagram, regardless of
   `--udp-registration`.
7. ~~Frames of length ≤ 1 bypass decryption.~~ **Fixed 2026-09-27:** only the empty
   keep-alive frame is exempt; a 1-byte frame is now a decryption error. The empty frame
   carries nothing and is still echoed as a keep-alive.
8. **The management API binds loopback as HTTP** by default (TLS keys off *routable OR
   ldap_enabled*), so the admin bearer token crosses `lo` in the clear — reachable by any
   local process or an SSH tunnel.
9. **Direct-IP** (L6), as above.

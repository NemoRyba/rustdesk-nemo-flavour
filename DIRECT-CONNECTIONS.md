# Direct connections and the port knock

**Implemented 2026-10-06.** Server-distributed direct endpoints, plus an optional
fwknop-compatible SPA knock in front of them.

Relay costs about a third of the link. Measured on the lab WAN path
(`LAB-VERIFICATION-2026-10-06.md`): the link carries 11.1 Mbit/s, a 20 MB transfer through
`hbbr` managed **7.1 Mbit/s — 64%**. `hbbr` itself was capped at 10 Gbit/s, so the loss is
the extra hop, not the relay's throughput. A workstation that can be reached through a port
forward should be reached that way.

---

## What it does

The management server publishes, inside the already-signed policy, where each workstation
can be reached without the relay. A controller that holds an entry for the id it is dialling
connects straight to it. When a direct endpoint is gated by SPA, the controller sends one
encrypted UDP packet first; the `fwknopd` on that site's edge opens the forwarded port for
that controller's source IP only, for a few seconds.

**Nothing about the existing path changes.** No endpoint for the id, no knock keys, a knock
that could not be sent, a refused connect, a handshake that cannot be anchored — every one
of those falls through to today's hole punch, then relay. That is deliberate and tested: a
fleet must not lose connectivity because a port forward broke. The cost of a dead endpoint
is latency (default 2.5 s), never reachability.

### Order of attempts

```
controller dials peer id
  ├─ 1. nemo-direct-endpoints has an entry for this id?   ──no──┐
  │     ├─ nemo-knock-enabled?  → send SPA, wait knock delay    │
  │     ├─ TCP connect to host:port                             │
  │     └─ Ed25519 handshake anchored on nemo-peer-keys         │
  │           ok → DIRECT, done.    anything fails ─────────────┤
  └─ 2. rendezvous: hole punch, then relay  ◄───────────────────┘   (unchanged)
```

Step 1 is skipped entirely for a forced-relay session and for `other_server` sessions
(a peer on someone else's rendezvous — its endpoints are not ours to know).

### Encryption on the direct path

The direct path is **not** weaker than the brokered one, and is never plaintext.

There is no rendezvous broker to hand over the peer's key, so `signed_id_pk` is empty and
the handshake falls through to `Client::secure_connection_direct`, which verifies the
controlled side's self-signed `SignedId` against the Ed25519 key the server pushed (signed)
in `nemo-peer-keys`, and binds it to the id the user actually asked for. Server-anchored,
no trust-on-first-use window. With `nemo-require-encrypted-session` on — it **defaults** on
— a peer whose key cannot be anchored is refused, not downgraded. So a direct endpoint
cannot buy an attacker a cleartext session.

**The knock is hardening over the port forward, not the session's authentication.** Losing
the knock costs you an exposed port; it never costs you session confidentiality.

---

## Configuration

### Per workstation — dashboard → Peers → (select) → Direct connection

`host:port`, optionally `,knockport`. `203.0.113.5:21118` or
`203.0.113.5:21118,62201`. This is the **router's external** address and port, not the
workstation's. A bracketed IPv6 literal works: `[2001:db8::1]:21118`.

Saving it also pushes `direct-server=Y` to that machine so its direct-access listener is
actually running. It listens on **21118** unless its device policy sets
`direct-access-port`; the port you typed above is the router's external port, which a
forward may translate (`31118 → 21118`).

Clearing it returns that machine to hole punch / relay.

Stored in `nemo_peer_endpoints.json` (override with `--nemo-peer-endpoints-file`).
**Operator-supplied only** — nothing in the client poll path can write it, because a peer
that could nominate its own endpoint could point controllers at an address it does not own.

### Fleet-wide — dashboard → ACL & Policy → Global client defaults

| key | default | meaning |
|---|---|---|
| `nemo-knock-enabled` | off | send an SPA packet before connecting to a direct endpoint |
| `nemo-knock-port` | `62201` | UDP port `fwknopd` listens on (an endpoint's `,knockport` overrides it) |
| `nemo-knock-key` | — | base64 Rijndael key = `KEY_BASE64` in `access.conf` **(secret)** |
| `nemo-knock-hmac-key` | — | base64 HMAC-SHA256 key = `HMAC_KEY_BASE64` **(secret)** |
| `nemo-knock-delay-ms` | `300` | wait after the knock before connecting |
| `nemo-knock-source-ip` | `0.0.0.0` | address to request access for; `0.0.0.0` = "use this packet's source IP" |
| `nemo-knock-user` | `tbfdesk` | username stamped in the packet (informational unless `REQUIRE_USERNAME`) |
| `nemo-direct-timeout-ms` | `2500` | whole-attempt budget before falling back |
| `nemo-direct-endpoints` | — | normally assembled per-controller; a hand-written map works when no per-peer endpoints are set |

### Who may change what

The **Allow clients to change these** switch on that panel is the policy's
`allow_user_override`, and it is what decides whether a technician can adjust the knock on
their own machine:

- **off** (recommended) → values land in `OVERWRITE_SETTINGS`: enforced, the client cannot
  change them locally.
- **on** → values land in `DEFAULT_SETTINGS`: pushed as defaults a user may override.

It applies to the whole policy, so when only *some* machines should be adjustable, push the
knock through a **named device policy** for those machines instead of the global one.

### What each client is told

Unlike `nemo-peer-keys`, the endpoint map is **filtered per controller**. A public key is
harmless to hand out; "here is a WAN address with a remote-desktop port behind it" is
reconnaissance.

- Only endpoints the controller's own `nemo-outbound-targets` already permits it to dial.
- **Never** a blocked peer's endpoint, so a controller cannot route around a block by
  dialling it directly.
- Sorted by id, so the value is byte-identical between polls and clients do not rewrite
  their stored policy every 30 s.

The two SPA keys are in `SECRET_POLICY_KEYS`: masked in dashboard responses, stripped from
any policy the server cannot seal to a device key (when `strip_unsealed_secrets` is on), and
masked out of the blob the client persists. The client therefore **cannot knock until its
first poll lands** (~10 s after start); until then its direct attempts fall back to relay.
That is the intended trade — a stolen config file must not hand over the fleet's knock.

---

## Setting up the edge

### 1. Port forward

On the workstation's site, forward an external TCP port to the workstation's
`direct-access-port` (21118 by default). With two routers in series, forward on both.

### 2. Generate the SPA keys

```sh
fwknop --key-gen
```

Put `KEY_BASE64` / `HMAC_KEY_BASE64` into both `access.conf` and the dashboard fields.

### 3. `fwknopd` — `/etc/fwknop/access.conf`

```
SOURCE                  ANY
KEY_BASE64              <paste KEY_BASE64>
HMAC_KEY_BASE64         <paste HMAC_KEY_BASE64>
REQUIRE_SOURCE_ADDRESS  N          # we send 0.0.0.0 = "use the packet's source IP"
OPEN_PORTS              tcp/21118  # the forwarded port
FW_ACCESS_TIMEOUT       10
```

`REQUIRE_SOURCE_ADDRESS N` is what makes `nemo-knock-source-ip=0.0.0.0` work, and that is
what you want from behind NAT — the client does not have to discover its own external
address (which would mean asking a third party). If you set it to `Y`, put each
technician's real external IP in `nemo-knock-source-ip` instead.

### 4. Where `fwknopd` runs

It must run where the traffic lands. **The external router cannot currently install it** —
see `OPEN-TODOS.md` 11c: the `kmod-*` chain needs a `kernel` package the EOL 19.07.1 feed
no longer serves. Until the routers are upgraded, per-workstation forwards are protected by
**source-IP allowlists** on the router instead, and `fwknopd` on the server VM covers the
server's own ports.

None of that affects this code. The packets are fwknop-compatible, so only
`nemo-knock-port` changes when the daemon moves.

---

## The SPA format

Recovered from fwknop 2.6.11 and verified in both directions. `nemo_direct.rs` builds:

```
plaintext = <rand16>:<b64 user>:<ts>:3.0.0:<msgtype>:<b64 "ip,proto/port">
plaintext += ":" + b64(SHA256(plaintext))
raw       = "Salted__" + salt8 + AES-256-CBC(plaintext)
                         key/iv = EVP_BytesToKey(MD5, 1 iteration, key, salt)
encoded   = base64(raw), '=' stripped
packet    = encoded minus its leading "U2FsdGVkX1"
          + b64(HMAC_SHA256(hmac_key, encoded))        # over the UNstripped form
```

The HMAC covering the form *with* the `Salted__` prefix — which is not the string that goes
on the wire — is the one non-obvious detail; the daemon re-adds the prefix before checking.

Three tests pin this down, and they are the contract with `fwknopd`:

- `spa_matches_a_real_fwknop_packet` — decrypts a datagram fwknop itself produced and
  recovers every field.
- `spa_encoder_reproduces_the_real_fwknop_packet` — given fwknop's own nonce, timestamp and
  salt, our encoder emits **byte-identical** output. If this ever fails, `fwknopd` has
  stopped accepting our knocks.
- `knock_is_accepted_by_a_live_fwknopd` — `#[ignore]`d, because it needs a daemon running.
  Sends a real knock through the production `knock()` path and lets `fwknopd` judge it. The
  test body carries the one-liner to start a daemon unprivileged (UDP server mode binds a
  high port, `-t` skips the firewall commands), so this is re-runnable in a few seconds.

Being wire-compatible means the audited daemon decides whether a knock is genuine. We never
have to be that authority.

### Verified against the real daemon, 2026-10-07

`fwknopd 2.6.11` in UDP + test mode, three knocks from our `knock()`, each accepted:

```
udp_server: Got UDP datagram (204 bytes) from: 127.0.0.1
(stanza #1) SPA Packet from IP: 127.0.0.1 received with access source match
[127.0.0.1] (stanza #1) SPA Decode (res=0):
   Random Value: 5481073202948673      Message Type: 1 (Access msg)
       Username: nemo                Message String: 0.0.0.0,tcp/21118
      Timestamp: 1791324349             Digest Type: 3 (SHA256)
    FKO Version: 3.0.0                    HMAC Type: 3 (SHA256)
                                    Encryption Type: 1 (Rijndael) / CBC
[127.0.0.1] (stanza #1) --test mode enabled, skipping firewall manipulation.
```

`res=0` is a full success: HMAC verified, decryption succeeded, every field recovered, and
it would have opened `tcp/21118`. Three distinct random values, no replay rejections — the
nonce varies correctly in practice.

Negative control, so the accepts mean something — the reference `fwknop` client with a
**wrong** HMAC key against the same daemon:

```
Error creating fko context: Args contain invalid data: FKO_ERROR_INVALID_DATA_HMAC_COMPAREFAIL
(stanza #1) Non-corresponding HMAC for this stanza
```

The daemon is genuinely enforcing. **The knock half is proven end-to-end against the real
daemon**; what is still untested is the knock opening an actual firewall rule on a real
edge, which needs a router that can host `fwknopd` (`OPEN-TODOS.md` 11c).

Crypto comes from `aes`/`cbc`/`md-5`/`hmac`/`sha2` (RustCrypto), all already in the lock
file. Not `openssl`, despite it having `pkcs5::bytes_to_key` ready-made: this crate only
links openssl on Linux/Android, and the knock has to work on the Windows workstations.

---

## Verifying it

Client log, direct path taken:

```
TBFDesk knock: sent 225 byte SPA to 203.0.113.5:62201 requesting 0.0.0.0,tcp/21118
TBFDesk direct: trying 203.0.113.5:21118 for 123456789 (budget 2500ms)
TBFDesk direct: established with 203.0.113.5:21118 in 412ms, no relay
```

Fallback, with the reason named:

```
TBFDesk direct: 203.0.113.5:21118 unusable (connection refused); falling back to hole punch / relay
TBFDesk direct: 203.0.113.5:21118 did not complete within 2500ms; falling back to hole punch / relay
```

In the session itself the connection-type badge reads **TCP** (direct), not **Relay**, and
the Peers table's *Forced Relay* counter stops advancing for that peer.

On the daemon side, `fwknopd -f -v` logs each accepted SPA with the source it opened for.

---

## Still open

**Done:** 8 client + 3 server tests, the byte-exact fwknop contract, and the knock accepted
by a real `fwknopd` with a working negative control (above).

**Not yet done — all of it needs a router change, so it is the user's half:**

- **A real port forward.** Nothing has yet connected to a direct endpoint over a live
  forward. On the lab server 21118/21119 are hbbs's own websocket ports and no client is
  running there, so there is no forward to borrow — this needs one workstation forwarded on
  both routers, then an endpoint set for it in the dashboard.
- **The knock opening an actual firewall rule.** Verified up to `res=0` and
  "would have opened tcp/21118"; the `-t` that made an unprivileged test possible is exactly
  what skipped the `iptables` call. Needs a host that can run `fwknopd` for real
  (`OPEN-TODOS.md` 11c).
- **Throughput on the direct path**, to confirm it recovers the missing ~36%.
- **`nemo-knock-port` forwarded** on the router to wherever `fwknopd` ends up.

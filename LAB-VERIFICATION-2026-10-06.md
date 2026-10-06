# TBFDesk lab server — end-to-end verification, 2026-10-05/06

Server `ubuntu24dev`, LAN **192.168.1.14**, public **85.126.226.2**. Everything below was
measured against that live server, not inferred from code. Where a claim rests only on
reading the source, it says so.

Final state: hbbs/hbbr `build_id e670ddb 2026-10-06`, both services active, 0 restarts,
`require_device_key` / `strip_unsealed_secrets` / `require_sealed_login` all **true**.

---

## 1. A real bug, found and fixed: every WAN→LAN session failed

This is the headline. The topology's whole purpose — a roaming controller reaching an
office workstation — **did not work at all**, and nothing in the test suite caught it.

Symptom: the client showed *"Verbindung über Rendezvous-Server ist fehlgeschlagen"*.
hbbs logged that it had brokered the session and then threw the answer away:

```
Nemo connect: target=206685844 source=91090423 nat=SYMMETRIC
connection-negotiation: forced_relay=true, same_intranet=false
Dropping unsolicited RelayResponse: no matching RequestRelay was forwarded
```

Two independent defects in the "mint relay grants only for sessions hbbs actually
brokered" hardening:

1. **The forced-relay flow was never taught to the grant check.** A target answers a
   `PunchHole` with a `RelayResponse` (`rendezvous_mediator.rs handle_punch_hole` →
   `create_relay` once hbbs stamps `nat_type=SYMMETRIC`), and the controller *waits* for
   that response (`client.rs`). No `RequestRelay` is ever sent to hbbs in this flow — the
   client's `set_request_relay` calls go to **hbbr**. But `pending_relay` was only
   populated by the `RequestRelay` arm, so the legitimate answer looked unsolicited.
2. **The key form was wrong on both sides.** `AddrMangle::encode` normalises through
   `try_into_v4` before encoding, so the lookup decodes a **V4** address — while a
   dual-stack listener reports the controller as the v4-**mapped** v6 `::ffff:a.b.c.d`.
   `V6-mapped != V4` for `HashMap` equality, so even the pre-existing `RequestRelay`
   insert could never match its own lookup.

Fixed in server `e670ddb`. The grant property is unchanged: the entry is keyed by the
controller address hbbs itself minted and the target echoes back untouched, names the
target hbbs actually pushed to (still cross-checked against the responder's proven device
key), is single-use, and expires with the grant TTL.

Regression test `forced_relay_punch_records_a_pending_relay_entry` looks the entry up the
way the `RelayResponse` arm does — through an `AddrMangle` encode/decode round trip —
because asserting on the raw address passes with the wrong key form and still fails live.
Suite: **82 passed** (was 81), 0 failed.

**Verified after deploying:** zero "unsolicited RelayResponse", and a full remote desktop
session established WAN→LAN showing the green encryption shield and the orange **Relay**
badge, streaming the remote screen live.

---

## 2. Encryption — measured on the wire, not assumed

Every transport was probed against the live server from the public internet, and the
rendezvous/relay offers were **cryptographically verified** (the probe checks the server's
Ed25519 signature over its ephemeral key with the published server key).

| Surface | Result |
|---|---|
| hbbs TCP 21116 | Key-exchange offer, **Ed25519 signature VALID**, fresh ephemeral key per connection |
| hbbr TCP 21117 | Same — **signature VALID**, distinct ephemeral key |
| Incomplete handshake | Connection **closed** (`key-exchange=require`, default, fails closed) |
| Plaintext injection | **Refused** — connection closed |
| UDP 21116 | No reply. Logged: *"Refusing plaintext UDP RegisterPeer (udp-registration=N)"* |
| WebSocket 21118/21119 | Logged: *"Refusing websocket rendezvous: no key exchange and no device-key proof"* |
| nemo-api 21120 | **TLS 1.3** (`TLS_AES_256_GCM_SHA384`); plaintext HTTP refused; 401 without token |
| Device-key layer | Unprovisioned probes refused: *"require-device-key is on …"* |

**Packet captures** (the strongest evidence):

- *Registration*, 30 packets: peer id, uuid and every protocol string — **0 cleartext hits**.
- *Management API*, 38 packets: no cleartext HTTP verb, URL path, bearer token or peer id.
- *Live relayed desktop session*, **3303 packets / 479 KB**: the one-time password `fgkw2g`
  → **0**; `TBFDesk` and `Einmalpasswort` — words literally **rendered on the remote screen
  inside the video stream** → **0**. Entropy 6.92 bits/byte, 256/256 distinct byte values.

The only cleartext is the `SignedId` handshake frame (`0a 09 <peer id> 12 20 <32-byte pk>`),
which must precede encryption and is *signed* — this fork hard-fails an invalid signature
(`"Encrypted session required by TBF policy: direct peer signature invalid (possible MITM)"`).
The public key is public by definition. A relay-side observer learns which peer id is in a
session, which it already knows from brokering it.

---

## 3. Measured performance

- WAN path (this box ↔ server, over the public internet): **11.1 Mbit/s down, 7.4 Mbit/s up**,
  RTT **64 ms** avg (min 59.7 / max 68.9, 0% loss).
- hbbr is configured at **10 Gbit/s** (`SINGLE_/TOTAL_/LIMIT_SPEED=10000`), so the relay is
  nowhere near the bottleneck — the internet link is.
- Idle relayed desktop session: ~20 kbit/s average (RustDesk only sends deltas; the remote
  screen was static).

A meaningful CAD/3D throughput figure still needs a controller on a real link and motion on
the remote screen; this run bounds the path, not the codec.

---

## 3b. Access control — enforced, in both directions

Tested by flipping policy on the live server and attempting a real connection each time.
The client messages are specific, not generic failures:

| Scenario | Server event | What the operator sees |
|---|---|---|
| Target blocked | `policy-rejection: target peer is not allowed by TBF policy` | *"target peer is not allowed by TBF policy"* |
| Controller blocked | `policy-rejection: peer is blocked` | *"Outgoing connections are disabled by TBF policy"* |

A blocked peer is also refused at **registration** (`register-pk: public key rejected`), not
just at connect time — so it cannot re-announce itself while blocked.

### Ending a session already in progress — CORRECTED, and then fixed

**An earlier revision of this file said force-disconnect did not exist. That was wrong,
and the error was mine: I pulled the wrong lever.** Recorded here because the wrong
version was committed, and because the difference matters operationally.

What is actually true:

- `/nemo/api/connections/cut` **does** end a running session. It blocks the peer *and*
  stamps a revocation (`set_peer_terminate`), which the controlled side reads as
  `terminate_sessions_before` on its next managed-policy poll and acts on by calling
  `terminate_all_authed_sessions` → `ipc::Data::Close` on every authorised session. The
  whole chain was already built on both sides; `OPEN-TODOS.md` #6 is stale.
- `/peers/:id/block` **did not** — it set the policy and nothing else. That is what I
  tested, and the session kept streaming (timer advancing 00:26:18 → 00:27:13).

So the real defect was not a missing feature but an inconsistency between two levers, and
the one that failed was the one named "block" — the one an operator reaches for to revoke a
compromised machine. Fixed in server `0c4c2ca`: `block_peer` now stamps the same revocation
`cut` does.

**Verified end to end after the fix**, on a live relayed session: the block stamped
`1791266853`, the client's `nemo-terminate-acked` matched it **within 20 s**, and the
session died with *"Von der Gegenstelle manuell geschlossen"* — the signature of the
client closing it on instruction, not a network drop or an "offline" timeout.

Two properties worth keeping in mind:

- **It is not instantaneous.** Teardown rides the policy poll, so budget up to one
  interval (`POLL_INTERVAL_SECS = 30`); measured 20 s. The dashboard's Cut confirmation
  used to claim "Active direct sessions end when closed" — corrected in the same commit.
- **It is performed by the controlled machine**, which is the right place: that is the
  asset the operator owns, and the controller cannot veto it. The poll is device-key
  gated and deliberately does *not* gate on peer status, so a blocked peer still receives
  the instruction telling it to hang up.

## 3c. Port forwarding / RDP tunnel — encrypted in source, NOT provable on the wire here

The CRITICAL fix is present and correct in source: `src/port_forward.rs` makes **zero**
calls to `set_raw()`, and its comment documents exactly the old failure ("both ends used to
call set_raw() here, dropping the session cipher AND the framing"). The stream stays framed
and encrypted — `send_raw()` seals each chunk, `next()` opens it.

**But I could not confirm it on the wire**, because the tunnel never carried data. Driving
the port-forward UI (local 19999 → remote `127.0.0.1:9999`, against a canary echo server)
produced a listening local socket and a real session — hbbs brokered it and the controlled
side logged `new connection #37: 91090423` — after which the controlled side's
per-connection child process **panicked**:

```
thread 'main' panicked at library/std/src/thread/local.rs:429:25:
cannot access a Thread Local Storage value during or after destruction: AccessError
```

The canary was never dialled, and two tunnel attempts timed out. The main client process
survives; desktop sessions over the same build are unaffected (one ran 27 minutes). So this
is specific to the port-forward path on the **Linux** controlled side in this headless
(Xvfb) lab. Production targets are Windows, so this may not affect the real deployment —
but **RDP-over-port-forward should be proven on a Windows target before anyone relies on
it**, and until then the end-to-end encryption of that path is a code claim, not a measured
one.

## 3d. Auto-update — the signed-manifest path works

Tested against the live server by publishing a manifest and verifying its signature
independently, the same way the key-exchange offers were checked:

- Publishing requires the admin token (**401** without it).
- `GET /nemo/api/update/latest` returns `{version, url, sha256, sig}`; with nothing
  published it is a clean **404**, not an unsigned shape.
- The signature is Ed25519 over `version|url|sha256`. **Verified valid** against the
  server's public key, and a one-character change to the version makes it **fail** — so
  the signature really does cover the fields a client decides on.

The test manifest was deleted afterwards (`/update/delete`, back to 404), so no client
will act on it.

## 3e. Permanent password — how to set one without an installed client

`--password` refuses unless `is_installed() && is_root()`, which a lab build satisfies
neither of, and the one-time password regenerates after every successful session — so
automation against it is a losing race.

The storage format makes this easy to do directly: it is a **hash, not a reversible
encryption** — `storage = "01" + base64(SHA256(password || salt))`
(`compute_permanent_password_h1`). Writing that value plus the matching `salt` into
`RustDesk.toml`, with `verification-method = 'use-permanent-password'` in
`RustDesk2.toml`, gives a stable password. Done on the lab VM and used for every session
since; the one-time field correctly shows `-` and no longer rotates.

Worth noting for the incident I caused: because it is a hash, a lost `password` value is
not recoverable and nothing secret leaks from the file — the only remedy is to set a new one.

## 4. Other things confirmed working

- Both clients authenticate with `auth_mode=device-key` — the rollout instrument from
  `REQUIREMENTS-SECURITY-LAYERS.md`.
- Device keys are **peer-id bound**: an unbound key was refused with
  *"device key has no peer-id binding (client claims 91090423); bind it"* (M1 hardening).
- The signed **peer-key map** is pushed by policy: the VM client's config gained
  `nemo-peer-keys` carrying both peers' public keys.
- `-r` now hands out the **public** address while LAN peers still get `local_ip`
  (`rendezvous_server.rs:882`/`:1411`) — verified in source before the change and in the
  live log after (`relay-servers=["85.126.226.2:21117"]`, `local-ip: "192.168.1.14"`).
- Signing key preserved across every redeploy (`zn4Abc…`), hbbs and hbbr identical, so no
  client was ever re-provisioned.

---

## 5. Still open

- **21118 / 21119 are forwarded on the router and should not be.** The server *refuses*
  websocket rendezvous outright, so these are attack surface for zero function. 21115 is
  correctly closed.
- **:21120 is public with a self-signed cert** whose SANs are `localhost, ubuntu24dev` —
  **no IP SAN**, so clients cannot validate it by address and fall back to
  `allow-insecure-tls-fallback`. With `require_sealed_request: false` (request bodies are
  plaintext *inside* TLS; responses are sealed), a MITM between a WAN client and :21120
  could read login/policy traffic. Fix with a real cert, or enforce the fingerprint pin,
  or keep :21120 behind WireGuard.
- **A client socket connects before the device key is loaded**, producing one
  *"presented no valid device key"* refusal immediately before each successful
  registration. Harmless today (the retry succeeds) but it matches known gap #1 in
  `REQUIREMENTS-SECURITY-LAYERS.md` and is noise in the log.
- **The port-forward path crashes the Linux controlled side's connection handler** (§3c),
  so that tunnel's encryption is source-verified only. Prove it on Windows before relying
  on RDP-over-tunnel.
- `OPEN-TODOS.md` #6 ("Real force-disconnect — cut only blocks NEW connections") is
  **stale** and should be closed; see §3b. The revocation it calls unbuilt has been built
  on both sides and is now verified working.
- Screen capture on the lab VM needs `RUSTDESK_FORCED_DISPLAY_SERVER=x11`, because its
  logind session is Wayland (gdm3) even when the client runs on Xvfb. Environmental, not a
  product defect — real targets are Windows workstations.

---

## Reproducing the client side

The lab VM now has a working Linux client built from source at
`~/rustdesk-nemo-flavour/rustdesk-client-nemo/target/release/rustdesk`. It needs
`libsciter-gtk.so` beside it, and:

```bash
XDG_CONFIG_HOME=$HOME/tbftest DISPLAY=:99 GDK_BACKEND=x11 \
  XDG_SESSION_TYPE=x11 RUSTDESK_FORCED_DISPLAY_SERVER=x11 LD_LIBRARY_PATH=. \
  ./target/release/rustdesk
```

Build prerequisites installed on the VM: the usual GTK/X11/codec `-dev` set plus
`libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev`, and `PKG_CONFIG_PATH` pointing at
`~/rustdesk-nemo-flavour/pkgconfig` for `libyuv.pc` (Ubuntu's `libyuv-dev` ships no `.pc`).

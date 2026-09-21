# Control-plane encryption, security review and CAD performance — 2026-09-20

Work done overnight on branch `nemo-tdd` in both submodules. **Everything is uncommitted
in the working tree.** Diffs: client +547/−97 over 8 files, server +799/−22 over 7 files.

Verification actually run (not claimed):

| | result |
|---|---|
| server `cargo build` + `cargo test` | clean, **56/56** (baseline before this work: 49) |
| client `cargo build --features linux-pkg-config` | clean (Ubuntu 24.04 container, see *Build note*) |
| client `cargo test --lib` | **69/70** — the one failure is `platform::tests::test_get_cursor_pos`, which asserts a live X11 cursor and cannot pass headless. That file is untouched. |
| TIScript (no compiler exists) | delimiters balanced, no dangling reference to the deleted `login()`, reviewed by hand |

**Every new switch defaults to OFF/false. At shipped defaults the wire is byte-for-byte
what it was, so a deployed fleet is unaffected until an operator flips something.**

---

## 1. What shipped

### (a) The plaintext login path is gone
`login()` — the legacy modal that POSTed `{username,password}` to `/api/login` in the
clear — is deleted (`index.tis`, was :2700-2761), along with its three dead callers
(`li#login` at :755, its handler at :779, the `act=="login"` dispatcher branch at :1599,
the top-level handler at :2403). The login-first gate (`nemoGateSubmit`) is now the only
sign-in path, and it seals the credential.

`loginPlain()` deliberately survives inside the gate: an unmanaged/dev client has no
management key to seal to, and deleting it would change that client's behaviour with no
flag to restore it. The **server** retires it instead — new setting `require_sealed_login`
(default false) rejects any `/api/login` without a sealed credential. An always-on
`log::warn!` names every client still sending one, so you can watch the log go quiet
*before* enforcing.

### (b) The whole request body is sealed, and so is the session token
- Poll and `/api/ab/get` now send exactly `{"sealed_request": base64(sealedbox(body+ts+nonce))}`
  when `nemo-sealed-request=v1`. Server opens it with the management secret key, enforces a
  300 s window and an at-most-once nonce, then continues through the existing logic.
  Gate: `require_sealed_request` (default false).
- **Login response sealing**: the client puts an ephemeral X25519 `reply_pk` inside the
  sealed credential; the server returns `sealed_access_token` instead of a cleartext token.
  No flag needed — the client's own request selects it, and an older server simply ignores
  the unknown field. Without this, sealing the login *request* was pointless: the response
  handed a MITM a live session token anyway.

### (c) The rendezvous key exchange the protocol always defined
`KeyExchange` was in `rendezvous.proto` and implemented in the client, but **had no server
implementation at all** — so `secure_tcp` could never complete against this hbbs, and
TCP-mode rendezvous was not a working fallback but an 18 s stall. (`hc_connection_`'s
`secure_tcp` call was also made conditional. Correction to an earlier claim: that path is
never entered against this hbbs, so this saved no time — it is a safety guard for the case
where the fleet is ever pointed at a server that does set `feedback`, not a latency win.) Implemented server-side:
`--key-exchange=off|offer|require` (default `off`), ephemeral X25519 signed with the hbbs
Ed25519 key, cipher carried with the `Sink` so it survives the move into `tcp_punch`,
encryption applied at the single `send_to_sink` funnel.

Client: `nemo-require-secure-rendezvous=Y` makes `secure_tcp` fail closed at one
enforcement point that neither the websocket skip nor an early return can bypass, and the
three side-channel connections that always sent in the clear (`create_relay`,
`handle_intranet_` — which leaks the workstation's internal IP — and `handle_punch_hole`)
get `secure_tcp` under the same flag.

**Not done, deliberately:** TCP *registration*. `handle_tcp` has no `RegisterPeer` arm and
answers `RegisterPk` with `NOT_SUPPORT`, so `disable-udp=Y` still takes a client offline.
That is a much larger surface and half-building it unattended could have taken the fleet
down. **Do not push `disable-udp=Y`.** A diagnostic log arm now explains it if someone does.

### Enable order — this matters
1. Deploy the new hbbs. Leave everything default. Nothing changes.
2. `--key-exchange=offer`. Confirm `key-exchange=offer` in the boot log. Clients ignore the
   unsolicited offer; punch/establish timings should not move.
3. Only then `nemo-require-secure-rendezvous=Y`, on **one** client first.
4. `nemo-sealed-request=v1` fleet-wide, then `require_sealed_request` once the log is quiet.
5. `require_sealed_login` last, after the plaintext-login warning stops appearing.

Reversing order at step 3 turns every rendezvous connection into an 18 s failure. There is
now a guard against exactly that (see SEC-4 below), but the order still stands.

Server-before-client also matters at step 4: a client with `nemo-sealed-request=v1` sends
the session token *inside* the envelope and no `Authorization` header, so an un-upgraded
server finds no token and answers `Invalid token` on `/api/ab/get`. Fail-closed and
correct, but it looks like a login bug if you push the client flag first.

---

## 2. Security review

8 adversarial finders across the whole attack surface, then two-lens refute-by-default
verification of the ranked findings — 36 agents. **14 findings confirmed, 0 refuted**, plus
52 lower-severity ones left unverified and listed in the raw output.

### Fixed tonight

| # | Sev | What | Where |
|---|---|---|---|
| SEC-1 | **CRITICAL** | `allow-auto-update` was applied unvalidated by `apply_policy`. The updater's version URL is hardcoded to **upstream** `api.rustdesk.com`, so one policy made every Windows workstation silently install stock RustDesk over the hardened fork with a privileged installer — wiping the login gate, sealed login, signed policy, blocked-ids, cert pin and licence-name provisioning, surviving key rotation and server rebuild. Now refused via an explicit deny list. | `nemo_management_client.rs` |
| SEC-2 | HIGH | *(our own new code)* Login-response sealing was undone one line later — `getAb()` put the same token straight back on the wire as `Authorization: Bearer`. The token now travels inside the envelope and no header is sent; the server prefers it and falls back to the header for older clients. | `ab.tis`, `nemo_management.rs` |
| SEC-3 | HIGH | *(our own new code; two findings, one root cause, one fix)* Unauthenticated memory exhaustion: the replay cache was bounded by entry **count**, not bytes, and the nonce is an attacker-chosen string consumed *before* any peer lookup. 1 MB nonce × 100 000 entries = OOM. Now `MAX_NONCE_LEN` (64) and `MAX_SEALED_REQUEST_B64` (16 KiB), both checked before any allocation. | `nemo_management.rs` |
| SEC-4 | MEDIUM | *(our own new code)* A hostile or merely mistaken policy could push `nemo-require-secure-rendezvous=Y` at a server running `--key-exchange=off` and brick the fleet across reboots. Enforcement is now gated on a `nemo-rendezvous-kx-seen` marker set only after a real handshake succeeds — the flag can only harden a path observed to work. **Trade-off, deliberate:** a client that has never completed a KeyExchange is never enforced, so a MITM that always strips the offer keeps that client unenforced and silent — the A7 first-contact pattern, on this leg. The marker is *not* policy-settable (by design: otherwise a hostile policy could set it and re-create the brick), so the only bootstrap is a real handshake. Pair the flag with provisioning that reaches the client out of band if first-contact matters to you. | `common.rs` |
| SEC-5 | HIGH | `id_ed25519` — the rendezvous signing secret the whole (b)/(c) design trusts — was written with `File::create`, i.e. **0644**. Any local account could read it, silently. Now created 0600, and an existing key is tightened on every start. | server `common.rs` |
| SEC-6 | HIGH | The controlled side's `nemo-require-encrypted-session` fail-closed was bypassable: a handshake reply that isn't a `PublicKey` message only logged and fell through with no key set — exactly the plaintext session the code's own comment claims to refuse. Replaced per-branch checks with one post-handshake enforcement point. | client `server.rs` |
| SEC-7 | MEDIUM | `nemo-api-cert-fingerprint` was write-once with no clear path: one malformed or hostile value permanently killed the only channel that could deliver a correction, across reboots. Now clear-on-omit like the other managed flags, and a value that isn't 64 hex digits is refused rather than stored. | `nemo_management_client.rs` |

Also corrected a comment claiming an opened envelope is "authenticated by the seal" — a
sealedbox is **anonymous**, so anyone with the management public key can produce one.
Nothing relied on it (both handlers still authenticate properly), but that is precisely the
"comment overstates the guarantee" pattern the September audit kept finding.

### Left for you — these are operational decisions, not code I should make alone

| # | Sev | What | Suggested fix |
|---|---|---|---|
| SEC-8 | HIGH | **LDAP direct-bind adopts an identity that never authenticated.** With the service-account Bind DN left blank, the typed string becomes the session identity → fleet-admin escalation. | After `simple_bind`, re-read the bound principal (RFC 4532 "Who am I?" or a scoped search) and refuse on 0 or >1 hits. Needs a real AD to test — I won't guess at it blind. |
| SEC-9 | HIGH | **No request-body size limit on any route** (axum 0.5 has no default) → unauthenticated OOM of the whole process, rendezvous included. | `tower_http::limit::RequestBodyLimitLayer::new(64*1024)` on the router. Needs the `limit` feature and changes the body type for every handler — a real compile risk I would not take unattended. |
| SEC-10 | HIGH | **Password spraying against AD is unthrottled** — the per-username backoff runs *after* the bind and limits nothing concurrent. Any domain account, including the service account, can be locked out in seconds. | Check the failure counter *before* binding (small, safe). Per-IP limiting needs `ConnectInfo` plumbing. |
| SEC-11 | HIGH | **Admin token is passed as a command-line argument** — every local user on the hbbs host can read it from `/proc`, which equals full fleet admin. | `--nemo-api-token-file` read 0600, or systemd `LoadCredential=`. |
| SEC-12 | MEDIUM | **Admin dashboard serves plaintext HTTP by default** unless LDAP is enabled. Tonight's work made the *client* leg confidential independently of TLS; the *admin* leg on the same box is still in the clear. | Default TLS on for any non-loopback bind; require an explicit `--nemo-api-allow-insecure`. Changing this could lock you out of your own dashboard, so it's your call. |
| SEC-13 | MEDIUM | Direct-IP / `host:port` controller path returns before any handshake, so feature B and the A5 identity binding never execute on it. `SECURITY-HARDENING-TODO.md` records both as delivered — false for that path. | Run `secure_connection` on that path too. |
| SEC-14 | — | The new rendezvous leg **inherits S-D** (both directions key from the same symmetric secret). Not newly introduced, and interop with the client requires it — but S-D's footprint is now wider. | Fold into the existing S-D ticket. |

Also: the dashboard still shows an "Auto update" checkbox (`nemo_admin.html:1164`). It is
now inert for managed clients. Remove it server-side so it doesn't mislead.

---

## 3. CAD performance

Six analysts across capture → encode → transport → input → decode → present. **Analytical
only — no measurement rig existed.** Every claim is labelled `[CODE]` / `[INFERRED]` /
`[ASSUMPTION]` in the raw output. The measurement plan below is the point.

**First, the verification you asked for:** no hunk of tonight's security work touches the
streaming hot path. The envelope is built on a **30 s** poll timer, login sealing is once
per human sign-in, the key exchange is once per TCP accept on the control socket. The
committed e2e baseline should not move beyond noise.

### The three things most likely to be hurting you, all config-only

1. **Default quality is `low`.** This fork sets `image_quality` default to `"low"` =
   ratio 0.5 (`config.rs:2319`). At 4K that is 2500 kbps CBR with VP9 quantiser band
   q 27..51. Pushing `image_quality=custom` + `custom_image_quality=100` moves it to
   q 0..37 and 4× the bitrate. This is the largest sharpness lever with no code change.
2. **The ABR loop is a one-way ratchet for this workload.** It only recovers when ≥6
   encodes happen in 3 s — which *reading a drawing never produces* — but it decays on any
   latency blip, and this fork lowered the floor from 0.1 to **0.01**. A 4K stream can park
   at 1 % of base. Push `enable-abr=N` for CAD peers; FPS adaptation is independent and
   keeps working.
3. **Chroma is 4:2:0.** A 1-pixel coloured line on black has no luma-only representation,
   so layer colours bleed across a 2×2 block. `i444=Y` per peer fixes it — but only while
   you stay on software VP9/AV1: the hardware path pins NV12, so **hardware encode and
   4:4:4 are mutually exclusive in this codebase**. That is the central trade-off for CAD,
   and `SPEED-AND-CODEC-RESEARCH.md`'s "enable hwcodec" and "use I444" items are in direct
   conflict — worth resolving explicitly.

### Notable finds
- **The shipping build has no hardware codec at all** — `build-run-windows-client.ps1:398`
  builds `--features inline`; upstream CI uses `inline,vram,hwcodec`. So H.264/H.265 are
  structurally unavailable in both directions, and `codec-preference=h264` silently falls
  back to software AV1.
- **The AV1 self-test benchmarks 1080p and applies the verdict at 4K.** 30 ms at 1080p
  becomes ~120 ms at 2160p — an ~8 fps ceiling on the machines that matter most.
- **VP9 is never told it's screen content.** AV1 sets `AOM_CONTENT_SCREEN` + palette + AQ;
  VP9 sets neither `VP9E_SET_TUNE_CONTENT` nor an AQ mode. Two `vpx_codec_control_` calls.
- **The controller's video queue is 120 frames — about 4 seconds** — and never drops to
  latest, so a 4K orbit burst converts directly into display latency.
- **hbbr's relay is a single loop over both directions**, so a video-direction stall (the
  bandwidth limiter sleeps in 100 ms quanta) also stalls input. Check `SINGLE_BANDWIDTH` /
  `TOTAL_BANDWIDTH`: the defaults throttle at 128 Mbit/s and permanently downgrade to
  32 Mbit/s after 30 minutes.

### Measure first, in this order
1. **Negative control**: run `e2e/measure-connection.ps1` on the new build at all defaults
   and diff against the committed baseline. Nothing should move.
2. Add **frame-interval and input-to-photon histograms** (not mean FPS) over a 60 s
   orbit/pan. The current harness measures connection setup, not interaction — this is the
   metric that decides whether orbiting feels right, and nothing measures it today.
3. `--key-exchange=offer` with all client flags off → punch/establish unchanged.
4. Then one client with `nemo-require-secure-rendezvous=Y`; record LAN-direct and WAN-relay
   separately (~2–3 RTT, and the two topologies differ by orders of magnitude).
5. Log `GetFrameDirtyRects` for a minute of real CAD work before touching capture. If a
   still drawing really is <1 % dirty, the readback win is large; if not, skip that work.

---

## Build note — the client now builds natively on Arch (fixed)

`libs/scrap` required **bindgen 0.65**, and **LLVM 22 changed the clang AST** in a way that
broke bindgen's handling of a struct that is forward-declared before it is defined. libaom
and libvpx do exactly that: the `config` union in `aom_codec.h` references
`aom_codec_dec_cfg` / `aom_codec_enc_cfg`, which are only defined later in
`aom_decoder.h` / `aom_encoder.h`. Every bindgen up to and including 0.72.0 emitted those
as opaque —

```rust
pub struct aom_codec_dec_cfg { pub _address: u8 }
```

— so all 64 field accesses failed with `error[E0560]: ... has no field named threads`.
Arch/Fedora ship clang 22 and broke; Ubuntu 24.04's clang 18 did not, which is why it only
ever failed locally. Fixed upstream in **bindgen 0.72.1**, which `libs/scrap/Cargo.toml`
now requires.

Verified after the bump: the client builds natively on Arch and **70/70 lib tests pass**
(the container's 69/70 was only `test_get_cursor_pos` failing for want of an X display).

New script: `scripts/build-arch-client.sh [--release]`. It checks the pacman packages
first and prints the exact `pacman -S` line if any are missing, then builds with
`--features linux-pkg-config` and the workspace `pkgconfig/` prepended (libyuv ships no
`.pc` on Arch either; `PKG_CONFIG_PATH` prepends, so system `.pc` files are still found).

The Ubuntu container recipe still works and is worth keeping for reproducing the
distro the fleet is built on:

```sh
podman build -t nemo-build -f Containerfile .   # ubuntu:24.04 + the README's dep list + libssl-dev
podman run --rm -v <client>:/src:ro -v <workspace>/pkgconfig:/pkgcfg:ro \
  -v nemo-cargo:/root/.cargo -v nemo-target:/target localhost/nemo-build bash -c '
    cp -a /src /build && cd /build && touch build.rs &&
    PKG_CONFIG_PATH=/pkgcfg:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig \
    CARGO_TARGET_DIR=/target cargo build --features linux-pkg-config'
```

`touch build.rs` is required there: `build.rs` calls `hbb_common::gen_version()` which
writes the gitignored `src/version.rs`, and cargo will reuse a cached build-script result
for a fresh copy and then fail on a missing `version` module.

## What I could not verify
- Nothing was run against a live server, a Windows client or an AD domain.
- No packet capture was taken, so "only ciphertext on the wire" is argued from code, not observed.
- The TIScript UI has no automated coverage at all; the gate changes were reviewed by hand.
- The `--key-exchange` handshake has a unit test for the crypto contract and argument order,
  but nothing exercises it over a real socket.

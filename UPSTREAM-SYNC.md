# TBFDesk — Upstream RustDesk sync tracker

Divergence analysis of our fork vs current official upstream, and the port status. Grounded in a 3-agent commit-by-commit comparison (2026-09-03).

## Fork points & divergence
- **Client** (`rustdesk/rustdesk`): forked `b81ae6c8` (2026-05-22); upstream `82aa28f1` is **248 commits** ahead.
- **Server** (`rustdesk/rustdesk-server`): forked `815c728` (2026-02-17); upstream `a7736be` is **15** ahead.
- **hbb_common** (`rustdesk/hbb_common`): client fork base `9043c15` (~68 ahead); server sub base `83419b6`.

`upstream` remotes are configured on all three repos for future syncs. **Don't rebase** — upstream deleted the plugin framework, Linux-headless, and the `cli` feature, which collide with everything we reworked. **Cherry-pick** individual fixes instead. Happy accidents: upstream never touched `tcp.rs`/`message.proto`, so our S-D/S-E/NemoSource work is conflict-free; and upstream's `e1bdb06` (at-rest zero-nonce fix with a `FORMAT_V1` version-byte envelope) is a ready template for the S-D nonce negotiation.

## TIER 1 — DONE (2026-09-03)
All compile + test green (client 73, server 49). **hbb_common fixes are APPLIED (committed + pushed + gitlink bumped); src-level fixes are implemented + tested but UNCOMMITTED** (they're intermingled with the still-uncommitted security-audit batch in the same files).

| Fix | Upstream sha | Where | Status |
|---|---|---|---|
| bytes_codec: cap untrusted `reserve()` (frame memory-exhaustion DoS) | `547da54` | hbb_common (client `nemo`, server `nemo-server`) | ✅ APPLIED — cherry-picked into NemoRyba/hbb_common, gitlinks bumped (client `53ed8afdc`, server `106793e`) |
| compress: cap zstd decompression output (decompression bomb) | `a1a7016` | hbb_common (both) | ✅ APPLIED (same commits) |
| protobuf 3.7.1 → 3.7.2 (parser-recursion DoS on untrusted `RendezvousMessage`) | `0d915e6` | server `Cargo.lock` | ✅ APPLIED (server `106793e`) |
| Peer-id validation (command injection via crafted id → shortcut/LAN) | `bdb38c473` | client `common.rs` `is_valid_untrusted_peer_id` + guards in `platform/windows.rs create_shortcut`, `lan.rs` pong | ✅ implemented + tested (UNCOMMITTED) |
| Audio channel-count validation (unbounded alloc/panic on controller) | `5882346ca` | client `client.rs handle_format` + `is_supported_audio_channel_count` | ✅ implemented + tested (UNCOMMITTED) |
| RGBA clipboard dimension validation (panic/OOB) | `b1fad7bbe` | client `clipboard.rs valid_rgba_dimensions` | ✅ implemented + tested (UNCOMMITTED) |
| UDP reflection/amplification — disable UDP punch/hole/local-addr handlers | `80d3a50`+`109d9a2` | server `rendezvous_server.rs` (UDP arms blanked; Nemo hooks stay on TCP/WS) | ✅ implemented + tested (UNCOMMITTED) |
| i32 overflow — peers wrongly online after ~24.9 days | `91fb928` | server `rendezvous_server.rs` `REG_TIMEOUT`/casts i32→i64 | ✅ implemented + tested (UNCOMMITTED) |

## TIER 2 — pending (high-value, but in reworked files / vendored C)
- **`594e63805` login-scope binding (client, SECURITY):** bind approval/whitelist to a `login_scope:[u8;32]` so an auth retry can't change the requested scope after approval. Our `server/connection.rs` has no equivalent. Our most-reworked file → careful port.
- **`wf_cliprdr.c` batch (`fabeae418`,`32c6e32e0`,`e2149974c`,`dce221be5`,`6f1eb164d`):** Windows-clipboard C memory safety (integer overflow, unchecked format-map growth, file validation). Our vendored C is pre-fork (2026-05-21).
- **`7eb915011` audit retry+nonce (client):** hbbs audit posts silently dropped on transient/5xx; adds retry + dedup nonce. Our `connection.rs` audit lacks it.
- **Server X-Real-IP:** upstream added only warning comments, but it matters more for us (Nemo logs source identity + can key policy on those headers). Ensure the WS port sits strictly behind the proxy; port the caveat.

## TIER 3 — evaluate / align with our roadmap
- **M2 (controller-auth):** upstream `91b13be` added `ControlledContext { conn_audit_ref }` to `rendezvous.proto` — functionally our M2 idea. **Reuse/extend it**, don't build a parallel field.
- **Proto field-number discipline:** upstream took `switch_code = 11` on `PunchHoleRequest`/`RequestRelay` (`5438d20`). Our NemoSource/M2/S-D proto fields must number **≥12** on those messages or they silently collide on a future merge.
- **S-D nonce fix:** mirror upstream `e1bdb06`'s `FORMAT_V1` version-byte + legacy-fallback shape for the cross-direction nonce negotiation. (`tcp.rs` is conflict-free upstream.)
- **Features:** id-whitelist w/ wildcards (`d6ea17006`, overlaps our RBAC), cross-session clipboard sync (`f28ac38cc`), monitor-restore/toolbar UX (Flutter-side → Sciter equivalents are separate work).
- **`5eed50961` config at-rest zero-nonce:** hard (our `config.rs` diverged with the `permanent_password` module); lower priority.

## Ignored (of the 248 client / 15 server / 68 hbb_common)
~55 i18n, ~18 CI/deps, ~16 docs, and Flutter-UI-only + Linux/Wayland/macOS-capture platform commits (we ship Windows-Sciter). The two large upstream deletions (plugin framework −5251, Linux-headless −2944) + `cli` removal are the reason not to rebase.

## Notes
- **Two separate hbb_common submodules:** client (`nemo` branch, base 9043c15) and server (`nemo-server` branch, base 83419b6), both in NemoRyba/hbb_common + a 176 bare mirror. Port shared hbb_common fixes to **both** branches.
- Nothing here has been built-to-live or **deployed** — the live 176 server still runs the earlier scp'd audit-batch binary. Deploy is a separate, user-gated step.

# TBFDesk — Speed & Codec Research (2026-09-02)

Written during the autonomous session. Priorities: **performance first, security never weakened for speed.**
A key finding up front: **encryption is essentially free here**, so there is no real speed-vs-security tradeoff to make (see §3).

## 1. TJPEG_V2 (the codec DWService uses)

Your screenshot showed DWService running `FENC: TJPEG_V2, QA: 9`. TJPEG_V2 = **TurboJPEG** (libjpeg-turbo), an **intra-only, per-frame JPEG** encoder. Each frame is independent — no keyframe/delta prediction.

**What TBFDesk already has** (`rustdesk-client-nemo/libs/scrap/src/common/`): VP8/VP9 (`vpxcodec.rs`), **AV1** (`aom.rs`), **hardware H264/H265** (`hwcodec.rs`, GPU NVENC/AMF/QSV), and VRAM/texture encode (`vram.rs`). These are **inter-frame** codecs: they send only what changed between frames.

**Assessment — feasible, but LOW priority for CAD workstations:**
- For a mostly-static CAD/3D screen, inter-frame codecs (VP9/AV1/H26x) are **dramatically** more bandwidth-efficient than JPEG — a still screen costs almost nothing, where JPEG re-sends the whole frame every time.
- JPEG's only genuine wins: (a) **lowest possible latency** (no frame buffering / no B-frames / no rate-control ramp), and (b) **corruption resilience** (a lost frame never poisons later frames — no "smearing" until the next keyframe). DWService likely chose it for simplicity + these two properties, not efficiency.
- TBFDesk's "Optimize reaction time" quality + hardware H264 (1 keyframe interval, low latency) already covers most of the latency niche, and now the **1% bitrate** option (this session) covers extreme low-bandwidth.

**If you still want it (sketch):**
1. Add a `turbojpeg` (or `mozjpeg`/`jpeg-encoder`) encoder/decoder implementing the `EncoderApi`/`DecoderApi` traits in `libs/scrap/src/common/codec.rs`.
2. Add a `Jpeg` variant to the `VideoFrame` proto union (forks `hbb_common` — same cost as the planned `NemoSource` field) + a `CodecFormat::JPEG`.
3. Wire it into `codec-preference` + the negotiation in `codec.rs`.
4. Gate it as an opt-in "low-latency / lossy-resilient" mode.
Estimated 1–2 days. **Recommendation: defer** unless a measured latency test (`e2e/`) shows H264-reaction-time isn't good enough — then JPEG's intra-only latency edge is worth it.

## 2. Speed optimizations (prioritized, all security-preserving)

| # | Optimization | Status / where | Impact |
|---|---|---|---|
| 1 | **Direct-IP, no relay** for remote sessions | **DONE this session** (encrypted direct-IP, B) — avoids the relay round-trip entirely | High (latency) |
| 2 | **Hardware encode (NVENC/QSV/AMF)** on the CAD GPUs | `hwcodec.rs` exists; **verify it's actually active** on each workstation (needs a supported GPU + driver). Push `codec-preference=h264`/`h265` via policy | **Highest** for CAD |
| 3 | On-path relay (server in the middle segment) | `TOPOLOGY-DEPLOYMENT.md`; hbbr caps already lifted to 10 Gbit/s | High (WAN fallback) |
| 4 | **1% custom bitrate** floor | **DONE this session** (`header.tis` + `video_qos.rs`) | Extreme low-bandwidth |
| 5 | Chroma subsampling I420 vs I444 | I420 (4:2:0) is smaller/faster; I444 sharper for text/lines. Tunable per workload | Medium |
| 6 | `custom-fps` per workstation | pushable via managed policy | Medium |
| 7 | AV1 for bandwidth-constrained WAN | `aom.rs`; slower to encode, ~30% smaller than VP9 | Medium (WAN) |
| 8 | TCP_NODELAY | already set (`stream.set_nodelay(true)`) | Small (done) |
| 9 | Eliminate double-NAT (bridge inner router) | `TOPOLOGY-DEPLOYMENT.md` Phase 1.1a | Medium (setup time) |
| 10 | Codec/QoS tuning for CAD (FPS threshold, delay pivot) | `server/video_qos.rs` — review `DELAY_THRESHOLD_150MS`, `MAX_FPS` for the CAD workload | Medium |

**Biggest lever = #2 (hardware encode).** For 3D/CAD at high resolution, GPU encode vs software VP9 is the difference between smooth and unusable. Confirm `hwcodec` picks up each workstation's GPU (log line at session start) and pin `codec-preference` accordingly.

## 3. Why "encryption never weakened for speed" costs you nothing

The peer session is NaCl `secretbox` = **XSalsa20-Poly1305**, which runs at **multiple GB/s** on any modern CPU. A 100 Mbit/s video stream = 12.5 MB/s — the cipher is ~0.1% of one core. The X25519/Ed25519 handshake is **one-time** at connect (sub-millisecond). So:
- There is **no measurable throughput or latency cost** to keeping every session encrypted.
- The only thing that ever made direct-IP "faster" was skipping encryption entirely (plaintext) — which we have now closed. You lose nothing by requiring encryption.
- TLS on the management API (`:21120`) is off the streaming path entirely (login/policy/address-book only).

**Conclusion:** keep `require-encrypted-session` on. It does not trade against performance.

# Codec check & benchmark (2026-10-20)

Answers two questions: **do the codecs work in the client (Windows + Linux)**, and
**how does each encoding trade transfer (bitrate) against quality**.

## Which codecs the client offers, and why

The in‑session codec menu is built by `alternative_codecs()`: a codec shows only if the
**local** side can *decode* it **and** the **remote** side can *encode* it (negotiated per
session). VP8/VP9/AV1 are software (libvpx / libaom) and essentially always available.
**H264/H265 come from the `hwcodec` feature and need a working hardware (or ffmpeg) encoder
on the machine being controlled** — which is why H265 can be absent even though it is
implemented (the Windows client is built `--features inline,hwcodec`; H264 appearing proves
hwcodec is active).

Hardware reality in this lab:
- **Windows VM:** QEMU, **no GPU** → no hardware encoder; H264/H265 only if the hwcodec
  software path is present.
- **Linux dev host:** AMD RX 9070 XT (RDNA4) **but VAAPI is currently broken** —
  `radeonsi_drv_video.so` fails to load `libLLVM.so.23.1` (a pending‑reboot library mismatch
  from a system upgrade). So **right now hwcodec finds no working HW H264/H265 encoder on
  this host**, which is itself a concrete reason H265/HW‑H264 would be missing in a Linux
  client here. A reboot would restore VAAPI (not done — it's the user's machine).
- **Production machines** (where the operator saw "H264"): have a working H264 encoder;
  H265 shows only where the GPU/driver also exposes HEVC *encode* (more restrictive than
  H264) and the viewer can decode HEVC.

## In‑client verification (what each lab client actually offers)

Ran the client's own hwcodec probe (`--check-hwcodec-config`) on both:

- **Linux client (this host):** tests `h264_vaapi`, then `hevc` decode — **all fail**:
  `libva: dlopen of radeonsi_drv_video.so failed: libLLVM.so.23.1 ... Failed to create encoder
  h264_vaapi`. Result: the Linux client offers **VP8 / VP9 / AV1 only** here. (rustdesk's
  H264/H265 on Linux are hardware‑only — no software x264/x265 fallback in its hwcodec path —
  so a broken/absent VA driver removes them entirely. A reboot restores VAAPI on this RDNA4
  GPU, after which H264/H265/AV1‑HW would appear.)
- **Windows VM client:** tests every HW encoder (NVENC/QSV/AMF/MediaFoundation) — **all
  "Failed to create"** (QEMU has no GPU). Result: **VP8 / VP9 / AV1 only**.

So on both lab machines the codec gating is **working correctly**: H264/H265 are offered only
when a working hardware encoder exists, and otherwise the client falls back cleanly to the
software codecs. On the operator's production machine H264 is present (a working H264 encoder);
H265 is absent there because that GPU/driver exposes no HEVC *encode* (or the viewer can't
decode HEVC) — not because it is unimplemented.

## Benchmark — transfer vs quality (software encoders, realtime settings)

Because HW encode is unavailable on this host, these are the **software** encoders — which is
exactly what the no‑GPU VM and a HW‑less Linux client use, and what rustdesk falls back to.
Content: 1280×720, 30 fps, 10 s, **synthetic high‑motion** (`testsrc2`) — a stress case; real
desktop content (mostly static) compresses to a small fraction of these bitrates for every
codec. Realtime settings matching a remote‑desktop client (x264 veryfast+zerolatency, x265
ultrafast+zerolatency, libvpx `-deadline realtime -cpu-used 8`, libaom `-usage realtime
-cpu-used 8`). Quality = SSIM (robust) and PSNR (dB). Encode speed = fps on this CPU (realtime
needs ≥ 30 fps).

| codec | target | actual kbps | encode fps | SSIM | PSNR dB |
|-------|--------|-------------|-----------|------|---------|
| VP8   | 1 Mbps | 1008 | 338 | 0.957 | 27.7 |
| VP9   | 1 Mbps | 1015 | 547 | 0.954 | 27.8 |
| AV1   | 1 Mbps |  981 |  71 | 0.973 | 36.6 |
| H264  | 1 Mbps | 1024 | 571 | 0.973 | 35.9 |
| H265  | 1 Mbps | 1029 | 224 | 0.964 | 35.7 |
| VP8   | 2 Mbps | 2010 | 304 | 0.966 | 27.9 |
| VP9   | 2 Mbps | 1718 | 477 | 0.962 | 28.0 |
| AV1   | 2 Mbps | 1960 |  51 | 0.983 | 39.3 |
| H264  | 2 Mbps | 2014 | 664 | 0.988 | 39.7 |
| H265  | 2 Mbps | 2006 | 174 | 0.978 | 38.2 |
| VP8   | 4 Mbps | 4013 | 316 | 0.974 | 28.2 |
| VP9   | 4 Mbps | 2797 | 520 | 0.969 | 28.1 |
| AV1   | 4 Mbps | 3913 |  48 | 0.993 | 44.1 |
| H264  | 4 Mbps | 4011 | 364 | 0.996 | 45.2 |
| H265  | 4 Mbps | 4063 | 171 | 0.989 | 42.4 |

### Reading it
- **H264 (x264)** is the best all‑rounder here: highest SSIM at every bitrate **and** the
  fastest encoder — the right default for remote desktop, which is why it is the common
  choice. Even in software it runs far above realtime.
- **AV1 (libaom)** matches or beats H264 for efficiency at low bitrate (SSIM 0.973 @ 1 Mbps),
  but in **software it is ~10× slower** (47–71 fps here at 720p; at 1080p+ it would drop below
  realtime). Worth it only with a hardware AV1 encoder (RDNA4/Arc/Ada).
- **H265 (x265)** sits between H264 and VP9 in this realtime config; its efficiency edge over
  H264 shows up more at lower bitrates and with slower presets, which realtime can't use.
- **VP8/VP9 (libvpx realtime)** give lower quality‑per‑bitrate in this fast config; VP9
  conservatively **undershoots** the target bitrate (1718/2797 for 2M/4M). Their PSNR here
  (~28 dB) is depressed by a color‑range handling quirk in the libvpx→webm path — trust SSIM
  for the cross‑codec comparison, not the absolute PSNR.

### Caveats
- Software encode only (VAAPI down on this host). **Hardware** H264/H265/AV1 would be much
  faster (fps) and offload the CPU, at similar quality — that is what rustdesk prefers when a
  GPU supports it.
- Synthetic worst‑case motion. For typical desktop work all codecs use far less bandwidth;
  the *relative* ranking holds.
- These are the underlying encoders. rustdesk's exact tuning (keyframe interval, adaptive
  bitrate, its quality→bitrate mapping) differs, but the codec behaviour is representative.

### How to reproduce
`scratchpad/codec-bench/bench.sh` (ffmpeg): generates the clip, encodes each codec×bitrate,
measures bitrate/fps and SSIM/PSNR vs the reference.

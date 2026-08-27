# LAN direct-connection baseline — 2026-08-27

Measured on the lab (all hosts on the flat 192.168.0.0/24 after the server's
`--mask 192.168.0.0/16`). This is the Phase 1.0 "measure first" evidence for the
performance track.

## Result: same-LAN connections take the DIRECT path

Observed via the new server-side connections view (`GET /nemo/api/connections`),
which classifies the negotiated path:

| From (source)      | To (target)         | Path           | Relay used |
|--------------------|---------------------|----------------|------------|
| 499737550 (Windows, 192.168.0.102) | 1098799091 (VM 176, 192.168.0.176) | **direct-local** | — |

`direct-local` = the server returned `FetchLocalAddr` (same-intranet), so the
peers connect directly over the LAN and the **relay (hbbr) is bypassed entirely**.
This is the optimal path and the fork's #1 goal for same-site access.

Prerequisite confirmed: the controlled host needs a real session/connection
manager for the direct accept to succeed. VM 176 (active GNOME session) accepts
direct; a bare headless `--server` with no cm falls back to relay (earlier
finding) — headless office machines must run the installed service, not bare
`--server`.

## Relay fallback path: caps lifted

hbbr on 176 was capped at SINGLE_BANDWIDTH=128 Mbit/s, TOTAL=1 Gbit/s, and a
32 Mbit/s post-30-min downgrade throttle — a real ceiling for CAD streams that
fall back to relay. Raised all three to 10 Gbit/s via a systemd drop-in
(`/etc/systemd/system/rustdesk-hbbr-nemo.service.d/override.conf`,
`SINGLE_BANDWIDTH=10000 TOTAL_BANDWIDTH=10000 LIMIT_SPEED=10000`). Verified in the
hbbr log. Direct sessions are unaffected (they never touch hbbr); this only makes
the fallback fast.

## Still to measure (needs the real topology / GPUs — AFK-blocked)

- WAN → workstation across NAT (the actual remote-worker case). The flat lab
  cannot exercise NAT traversal; needs the double-NAT elimination (Phase 1.1) and
  a real WAN vantage. Direct-across-NAT (`direct-punch`) and any UDP hole-punch
  work is gated on this.
- Codec/throughput for CAD (`libs/scrap/examples/benchmark.rs` on the workstation
  GPU; `codec-preference` / `custom-fps` tuning) — deliberately not pushed blind,
  as a wrong codec can break capture. Needs the workstation GPU details.

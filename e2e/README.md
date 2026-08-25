# Nemo E2E + performance measurement (Layer 4)

This directory is the measurement layer of the TDD strategy. It answers the only
question that decides the performance roadmap: **for a given topology and set of
options, does a session go direct or via relay, and how fast does it connect?**
Everything else (enabling UDP punch, tuning the relay, evaluating WireGuard) is
gated on the numbers this produces.

Full roadmap: `..\..\.claude\plans\analyze-this-repository-and-fizzy-parrot.md`
(or wherever you keep it). This README is the runbook.

## Contents

| File | Purpose |
|------|---------|
| `analyze-connection-log.ps1` | Parse a client log → per-connection facts (path, punch ms, establish ms). Pure text; verified by `-SelfTest`, no client/VM needed. |
| `measure-connection.ps1` | Drive N `--connect` attempts, capture logs, emit `results/<label>.csv` + a summary. |
| `results/` | Committed CSV evidence, one per run (e.g. `wan-baseline.csv`, `wan-after-middle-server.csv`). |

The parser keys off two lines the client logs per outgoing connection, in
`rustdesk-client-nemo/src/client.rs`:

- `"<n> ms used to <TCP|UDP> punch hole, relay_server: <addr>, <is_local|nat_type>"`
- `"<dur> used to establish <typ> connection with <punch> punch"` — `typ` is
  `Relay` for a relayed session, else `TCP`/`UDP`/`IPv6` for direct.

`path` is classified as `local` (same-LAN direct), `direct-tcp`,
`direct-udp-kcp`, `direct-ipv6`, or `relay`.

## Quick check (works today, no VM)

```powershell
./analyze-connection-log.ps1 -SelfTest   # exit 0 = parser correct
```

## Recommended VM topology (matches the roadmap decision)

Your network is a cascading double router (outer = Linksys WRT1900ACv2, inner =
TP-Link WDR4300 v1, both OpenWrt). Set the VMs up to mirror the target
production layout:

1. **Collapse the double NAT (OpenWrt config, no hardware change).** Bridge the
   inner router as a dumb AP (LAN-to-LAN, DHCP off, WAN unused) so there is one
   flat LAN and a single NAT at the outer router. This is what makes direct
   paths and (later) hole punching predictable.
2. **Server VM near the workstations**, on the LAN. Run `hbbs` (rendezvous) and
   `hbbr` (relay) on it.
3. **Outer router: forward only to the server VM** — `21116/tcp`, `21116/udp`
   (hbbs), `21117/tcp` (hbbr). Workstations need **no** inbound rules; they only
   connect outbound.
4. **Keys.** Generate one server keypair, configure every client with the
   matching public key. For local testing, the simplest is to run `hbbs -k <pub>`
   with the same key baked into the client (locked-exe filename or
   `custom-rendezvous-server` + `key` options). Note the current repo has a
   key mismatch between the local dev server and the packaged clients — fix that
   first (roadmap Phase 0.3) or nothing authenticates.

VM roles for a measurement run:
- **workstation VM** — runs the client as the controlled side (the `--server`
  process / normal client), registered to hbbs, gets an ID.
- **controller VM** — runs `measure-connection.ps1 --connect <workstation ID>`.
  Put this one *outside* the LAN (a second NAT, or a cloud VM) to measure the
  real WAN→workstation case, which is the one currently forced onto relay.

## Measurement workflow

```powershell
# 1. Baseline (current behavior — expect 'relay' for WAN→LAN today):
./measure-connection.ps1 -ClientExe <path to rustdesk.exe> `
    -PeerId <workstation ID> -Count 20 -Label wan-baseline

# 2. Change ONE thing (e.g. collapse the double NAT, or move the server,
#    or flip the relay-forcing rule once it is configurable).

# 3. Re-measure with a new label:
./measure-connection.ps1 -ClientExe <...> -PeerId <...> -Count 20 -Label wan-after-change

# 4. Compare:
Import-Csv results/wan-baseline.csv | Group-Object path
Import-Csv results/wan-after-change.csv | Group-Object path
```

Each run prints a path distribution, the % direct, and the median establish
time, and writes the raw rows to `results/<label>.csv`.

## Acceptance targets (from the roadmap)

- **LAN→LAN**: `local` (direct) on ≥95% of attempts.
- **WAN→workstation** via the on-path relay: establish < 1.5 s, and the relay
  adds < 5 ms RTT versus a LAN-direct session (measure RTT separately in-session;
  the establish time is the connection-setup cost this harness captures).
- No attempt should silently fall to relay when a direct path was expected —
  investigate any `relay` row in a topology meant to be direct.

## Runtime details to confirm on the first VM run

These depend on the actual build and can't be pinned from source alone:

1. **Log capture.** `measure-connection.ps1` sets `RUST_LOG=info` and redirects
   the process stderr. If your build writes logs only to a file (RustDesk's log
   directory) rather than stderr, pass `-LogPath <that file>` and it will parse
   that instead. Check the first run's output: "no connection event parsed" for
   every attempt means the log went somewhere else — find the log file and use
   `-LogPath`.
2. **Session teardown.** The connect window is force-terminated after
   `-DwellSeconds` (default 8). If the client leaves child processes, extend
   `Stop-Session` in the driver.
3. **In-session RTT / bitrate.** Not captured here yet. Use the client's own
   connection-quality overlay, or extend the analyzer once the exact log line
   for round-trip/bitrate is confirmed on a live session.

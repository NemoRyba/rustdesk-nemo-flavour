# Handoff: 1.4.8 upgrade on pc2 — "refused" was the NAT probe, and how to read registration

**Date:** 2026-10-17
**Box:** pc2 / tbfpc2, peer id `352069946`, appears at the server as `192.168.1.2` (NAT).
**Server:** ubuntu24dev `192.168.1.14`, `rustdesk-hbbs-nemo.service`.

## TL;DR
- After the 1.4.8 upgrade, pc2 **was registered and device-authenticated the whole time.**
- The `Refusing … require-device-key is on and this client presented no valid device key`
  lines (rendezvous_server.rs:2188), exactly **one per client service start**, come from the
  client's **NAT-type probe**, which connects to 21116 and sends a bare `TestNatRequest`
  without the device-key handshake. That is a real bug (below) — but it is not "pc2 offline".
- Consequence of that bug: NAT type detection always fails under `require-device-key`, so the
  server logs `nat=UNKNOWN_NAT path=relay` and peers fall back to relay instead of attempting
  hole punching.
- Client **1.4.9** adds a registration badge next to "Ready" so this is visible in the GUI.

## How it was misread (so nobody repeats it)
1. The refusal line looked like the device's rendezvous registration being rejected.
2. The server's success line (`secured and device-authenticated as peer …`, rendezvous_server.rs
   ~2138) is `log::debug!` → invisible at the default INFO level.
3. `update_pk` (peer.rs:112) only logs when the stored pk **changes** — a re-registration with the
   same key is silent.
4. So the log showed *only* failures, from the NAT probe, and no successes at all.

## Ground truth that settled it
- `ss -tnp state established` on the server shows a **long-lived** connection
  `192.168.1.2:<port> → :21116` owned by hbbs, whose source port is the refused one **+1**
  (e.g. refused `:3381`, kept `:3382`). Refused = probe; kept = the mediator.
- The client `--server` log shows one `start tcp` followed by steady `Latency of …:21116`
  pings. `update_latency()` runs only on server **answers** (RegisterPk/RegisterPeer responses),
  and with `require-device-key` on an unproven connection is closed before any answer.
- The installed client contains the `None`-branch warning `"No device key imported …"` and it
  never appears in its logs → it always takes the sealed-proof branch.
- Device key `VRfBtOT…` → public half `UsWm5cCC…` == the server's registered key for `352069946`.

**How to check registration from now on:**
- Client 1.4.9+: the badge next to "Ready" (`Registered` / `Not registered` / `No device key`).
- Server: `sudo ss -tnp state established | grep <client-ip>` → a persistent `:21116` connection.
- For success lines in the log, run hbbs with `RUST_LOG=debug` temporarily.

## Bug to fix: the NAT probe has no device-key handshake
`rustdesk-client-nemo/src/common.rs` `test_nat_type_()` uses `socket_client::connect_tcp_local`
and sends `TestNatRequest` directly. hbbs offers the key exchange first and, under
`require-device-key`, refuses any connection whose first reply is not a proof
(`_ => pending` → `authed == None` → :2188). Options:
- **Client (preferred, keeps "no proof, no service"):** run the same secured handshake
  (`secure_tcp` with the device proof) on the probe socket before sending `TestNatRequest`,
  keeping the local-address reuse the probe needs (and the same for the second port, 21115).
- **Server (smaller):** answer a pending `TestNatRequest` without auth — it only echoes the
  observed port — while still refusing everything else.
Verify afterwards: the per-start `2188` line disappears and `Nemo connect … nat=` is no longer
`UNKNOWN_NAT`.

## Server deploy done in this session
- Deployed `hbbs` built from **`94c12b7`** (current `nemo-tdd` tip, hbb_common `7ad1c09`),
  replacing a binary copied in at 2026-10-17 09:15. Built in a throwaway worktree so the VM
  checkout (`e670ddb` + uncommitted `nemo_management.rs` / `nemo_admin.html` WIP + live
  `db_v2.sqlite3`) was not touched. Rollback copies: `/usr/bin/hbbs.bak-predeploy-20261017-214356`
  and `/usr/bin/hbbs.bak-rollback-*`.
- **Gotcha:** the VM checkout `e670ddb` does **not** know `--nemo-client-api-bind`, which the unit
  passes → a binary built from it exits 1 at argument parsing and the unit crash-loops. Build
  from the commit the unit's flags expect (≥ `946680d`).
- **Gotcha:** `cp` over a running `/usr/bin/hbbs` fails with "Text file busy" — stop the unit first.

## 1.4.8 migration notes (separate, still worth fixing)
The 1.4.8 identity migration worked on pc2 (id + device key carried to the user and the service
profile), but it copies every file in the config dir: on pc2 that included `db_v2.sqlite3*` (a
server DB on a `\\dc` redirected profile), confy thread-temp files and `.bak-*` backups renamed
into the TBFDesk namespace. Restrict it to the file names `Config::file_()` produces, preserve
mtimes, and make identity migration all-or-nothing (roll back and retry next start rather than
ever generating a new id).

## pc2 state after this session
- TBFDesk **1.4.9** (registration badge) installed; service `TBFDesk`, config `%APPDATA%\TBFDesk`
  and the LocalService service profile hold id `352069946` + device key `VRfBtOT…`.
- Removed the experimental copy of the config under the SYSTEM profile path (unused: the config
  layer maps `systemprofile` to the LocalService profile).

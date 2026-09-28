# TBFDesk — Middle-Segment Server Deployment (prep)

**Status:** prep for when the two routers are set up. **Created 2026-09-02.**

## The plan (yours) and the correction

You said: *place the server between the two routers so hole punching can be possible, and the server can reach the workstation LANs.*

**The reach part is exactly right and it's the whole win. The "hole punching" part is a misconception worth catching now:**

- Putting the server in the middle segment, reachable to the workstation LANs, makes the server's **co-located relay an on-path, near-direct fast path** — and lets same-LAN peers connect **directly**. That is what gives you speed.
- It does **not** enable internet hole-punching between a roaming controller and a workstation, for two reasons: (1) this fork's server **has no UDP hole-punch** (the rendezvous proto predates it — no `udp_port`/`is_udp`/`force_relay`), and (2) it deliberately **forces relay on a WAN↔LAN mismatch** (`rendezvous_server.rs` `peer_is_lan ^ is_lan`). Double-NAT punch is also unreliable in general.
- **You don't need punch.** For a WAN controller → office workstation the traffic must cross the internet regardless; on-path relay adds only the one edge hop at the server (which sits at the office edge). The latency difference vs. a hypothetical direct punch is small, and punch would be fragile. **On-path relay + direct-LAN is the correct architecture here.**

So: **middle-segment server ⇒ fast on-path relay for remote (WAN) sessions + true direct for same-LAN sessions.** Hole-punch stays an optional, gated, later optimization (see bottom).

## What connects how (with this topology)

| Controller | Target | Path the server chooses | Speed |
|---|---|---|---|
| On the office LAN (192.168.x) | Workstation on LAN | **direct** (LAN↔LAN → FetchLocalAddr) | LAN-native |
| Roaming / internet (WAN) | Workstation on LAN | **relay** (forced by WAN↔LAN), on-path through the middle server | near-direct (server↔workstation is LAN-speed; only WAN→server is internet) |

"LAN" = any address inside the hbbs `--mask` (currently `192.168.0.0/16`). Make sure the mask covers **every** internal segment (middle segment + workstation LANs). If a segment uses a different range (e.g. `10.0.0.0/8`), widen/add the mask.

## Router / forwarding (outer router → the server)

Workstations stay **outbound-only** (no inbound rules on them). Forward only to the **server**:

| Ext port | Proto | → Server | Purpose |
|---|---|---|---|
| 21116 | TCP | :21116 | hbbs rendezvous |
| 21117 | TCP | :21117 | hbbr relay (the on-path fast path) |
| 21120 | TCP | :21120 | nemo-api: login, policy, address book |

**UDP 21116 is deliberately not forwarded.** This row used to say "TCP + UDP". It no
longer applies: `--udp-registration` defaults to `N`, so hbbs *refuses* plaintext UDP
registration — that transport carries no key exchange and no device-key proof, so
accepting it would bypass both `--key-exchange` and `require-device-key`. Clients default
to `disable-udp=Y` to match, and hbbs skips its own UDP self-test because the arm it
probes refuses by design. Forward UDP only if you deliberately pass `--udp-registration Y`.
Unrelated to UDP hole punching, which is a separate client switch (`enable-udp-punch`) and
is not implemented in this fork at all (see the bottom of this file).

Ports **21115** (hbbs NAT-test helper) and **21118 / 21119** (websocket rendezvous/relay)
stay unforwarded too. ws rendezvous is not merely unused — `rustdesk-server-nemo`'s
`rendezvous_server.rs` refuses that branch outright, for the same "no key exchange, no
device-key proof" reason.

Double-router: outer forwards `ext → inner-WAN-IP:port`, inner forwards `port → server`. **Better:** bridge the inner router to one flat LAN (dumb AP) so it's a single forward and one predictable NAT — recommended in the roadmap (Phase 1.1a).

## Client config split (important)

One client points at one rendezvous address, so location matters:

- **Controlled workstations (on the LAN):** `custom-rendezvous-server` = the server's **LAN IP** (`192.168.0.176`), `relay-server` = same, `api-server` = `https://192.168.0.176:21120`. (This is already how they're set.)
- **Roaming / WAN controllers:** the server's **public IP** (the outer router's WAN address) or a hostname.
- **Cleanest:** a **split-horizon DNS** name (e.g. `tbfdesk.yourco.com`) that resolves to the LAN IP inside and the public IP outside — then every client uses the same address and just works from either side. Push it to all clients via the managed policy (`api-server` / `custom-rendezvous-server`). Do this once and never re-key clients when the WAN IP changes (also bake it into the locked-exe name).

## Server config (already correct — verify after moving)

- hbbs: `-r <server>:21117 --mask <covers-all-internal> -k _ --nemo-api Y --nemo-api-bind 0.0.0.0:21120 --nemo-api-token … --nemo-api-tls auto` (systemd `rustdesk-hbbs-nemo.service`).
  The token is **mandatory, not advisory**: on a routable `--nemo-api-bind` hbbs exits at
  startup with *"Refusing to bind Nemo management API to 0.0.0.0:21120 without
  --nemo-api-token"*. Supply it as `NEMO_API_TOKEN=` in `/etc/tbfdesk/hbbs.env`, never on
  the command line — argv is world-readable through `/proc` (SEC-11). The shipped unit
  does this already, and hbbs accepts the underscore spelling precisely so an
  `EnvironmentFile` (whose keys cannot contain dashes) is enough on its own.
- hbbr needs the **same** signing key as hbbs (`-k _` + the shared `id_ed25519`); both log
  an identical `Key:` line at startup, and a mismatch breaks relay pairing. Its relay
  address must be routable — hbbr treats any loopback connection as its command port, so
  a `127.0.0.1` relay address can never pair.
- hbbr relay caps already lifted to 10 Gbit/s (`SINGLE_/TOTAL_/LIMIT_SPEED=10000`, systemd drop-in `rustdesk-hbbr-nemo.service.d/override.conf`) — so the on-path relay is not throttled.
- When the server IP changes with the move: update the workstations' `custom-rendezvous-server`/`relay-server`/`api-server` (via managed policy or DNS), and hbbs `-r`.

## Validate when the topology is up (harness is ready)

Use `e2e/`:
1. `measure-connection.ps1` from a WAN controller → workstation: confirm **path = relay** and measure setup time + RTT + sustained bitrate.
2. From an on-LAN controller → workstation: confirm **path = direct-local**.
3. Compare against `e2e/results/lan-direct-baseline-2026-08-27.md`.
4. Acceptance: relay adds < ~5 ms RTT vs LAN-direct, sustains the codec bitrate, setup < 1.5 s. If the on-path relay misses these, *then* the hole-punch gate opens.

## Only if on-path relay misses targets — the hole-punch task (Phase 1.4, deferred)

Substantial, gated, and probably unnecessary here. Would require: fork `hbb_common`, add `udp_port`/`is_udp`/`force_relay` to the rendezvous proto, implement the `TestNatRequest` UDP arm + `handle_hole_sent` routing in `rendezvous_server.rs`, make the WAN↔LAN relay-forcing conditional, and flip the client's `enable-udp-punch` default. Do not start this unless measurements demand it.

# Why lenovo → pc2 never went direct — and what makes the real test work

**Date:** 2026-10-18 · **Controller:** mareks-lenovo, id `480170882` · **Target:** tbfpc2, id
`352069946`, endpoint `85.126.226.2:21666`.

Router names below are the ones in [TOPOLOGY-DEPLOYMENT.md](TOPOLOGY-DEPLOYMENT.md):
**Router A** is the internet router (`85.126.226.2`, LAN `192.168.1.1`), **Router B** is the
office router behind it (WAN `192.168.1.2`, LAN `192.168.0.1`). The 2026-10-18 pc2 report used
the two names the other way round; it is the same two devices.

```
lenovo ──internet──▶ 85.126.226.2:21666 ──[Router A]──▶ 192.168.1.2:21666 ──[Router B]──▶ pc2 192.168.0.102:21118
                                        ▲
                                        └── the connection stops HERE: Router A answers it itself
```

## Update 2026-10-18 21:54: fixed and verified on the real machines

After the operator corrected the forwards on both routers:

- **From outside:** `scripts/probe-direct-endpoint.py 85.126.226.2:21666 352069946` →
  `PEER 352069946: connected in 63 ms and the right workstation answered with its signed
  id (115 bytes)`.
- **From the lenovo's own network** (public IP `92.180.230.164`, over SSH via Tailscale):
  TCP connect in 61 ms, 115 bytes carrying pc2's id.
- **With the lenovo's installed client** (1.4.9, normal connect, automatic mode):
  `TBFDesk direct: established with 85.126.226.2:21666 in 83.909ms, no relay`. The session
  then logged in and streamed (AV1, 30 fps).

The lenovo's own log from the day before also shows the failure as the client saw it:
`TBFDesk direct: trying 85.126.226.2:21666` at 22:46:28.7, then `unusable (Failed to
connect to 85.126.226.2:21666)` at 22:46:31.0. That is 2.25 s, i.e. dropped packets, not
an instant refusal. The router configuration was being changed during these days; both
symptoms come from the same forward.

**Speed, same path, one run each** (TCP tunnel lenovo ← pc2 ← Hetzner test file;
details in OPEN-TODOS 28): **direct 7.7 Mbit/s vs relay 4.6 Mbit/s.** Direct is 67%
faster. The lenovo's own download is 11.9 Mbit/s.

What follows is the investigation as it stood before the fix.

## Verdict

1. **Router A rejects TCP 21666 itself instead of forwarding it to Router B.** A connection
   from the internet to `85.126.226.2:21666` is answered with a TCP reset by Router A within
   one round trip. The SYN never reaches Router B or pc2. The client sees "refused", falls
   back within one round trip, and the session runs over the relay. This is the cause today.
2. **The lenovo had not been polling the management server.** On 2026-10-17 the server
   listed it as "allowed but never polled", so it held no direct endpoint and no peer keys.
   It never even attempted the direct path, and the builds it ran logged nothing about that.
   That was the earlier cause. It is gone: on 2026-10-18 at 10:47 UTC the lenovo polls and
   receives pc2's endpoint.

No fault was found on pc2, Router B, the server or in the direct protocol (§1, §2). One
limit applies: Router B's forward was proven for traffic coming from the DMZ. Traffic from
the internet can only reach it once Router A forwards, and the §4 probe checks exactly
that leg.

## 1. Evidence for Router A

All probes ran from `150.228.29.183`, which is outside both networks, on 2026-10-18.

**Unforwarded ports are dropped, but 21666 is reset.**

| port on 85.126.226.2 | result | what is behind it |
|---|---|---|
| 21665, 21667, 21120, 31337, 40000 | **timeout** (silently dropped) | nothing: Router A's WAN default is DROP |
| **21666** | **refused in 64 ms** | a rule for 21666 exists, but something answers it with a reset |
| 21116, 21117, 21118, 21121, 1234 | open | forwarded to the hbbs VM `192.168.1.14` |

If Router A had no rule for 21666, the port would time out like the others. The reset shows
that a rule exists and that the connection is delivered somewhere that refuses it.

**The reset comes from Router A itself.** The reply TTLs were captured with tshark.

| reply | TTL on arrival | sender |
|---|---|---|
| SYN-ACK from 21116 / 21117 / 21118 / 21121 / 1234 | **48** | hbbs VM: Linux, starts at 64, one hop *behind* Router A |
| **RST for 21666** | **49** | starts at 64, **one hop closer**: Router A |

A reset from Router B, which sits in the DMZ like the VM, would arrive with TTL 48. One from
pc2 (Windows, starts at 128) would arrive around 111. 49 can only be Router A.

**Router B, pc2's listener and pc2's firewall are fine.** The other session tested from inside
the DMZ: `192.168.1.14 → 192.168.1.2:21666` delivered pc2's validly signed handshake. pc2's
signature verified against the server-distributed key, the id bound to `352069946`, the sealed
session key was accepted, and pc2's first encrypted frame decrypted. The whole exchange took
4–65 ms.

**The two "refused" observations are one fault.** From inside the DMZ the VM also got an
instant "refused" on `85.126.226.2:21666`. That was read as missing NAT reflection. With the
outside result, the simpler reading covers both: Router A terminates 21666 on itself, for
every source.

### Most likely misconfiguration on Router A (OpenWrt 19.07)

One of these produces exactly a reset with Router A's TTL:

- a **Port Forward whose "Internal IP address" is empty**. LuCI then redirects the port to
  the router itself, where nothing listens on 21666, so it resets;
- a **Traffic Rule that opens 21666** (input accept) instead of a Port Forward;
- a forward whose internal IP is Router A's own `192.168.1.1`.

## 2. What the server says (peers API, 2026-10-18 10:47 UTC)

| | lenovo `480170882` | pc2 `352069946` |
|---|---|---|
| online, auth | yes, device key (proved 10:15Z) | yes, device key |
| direct endpoint | — | `85.126.226.2:21666` |
| endpoints delivered on its poll | **1** (pc2's) | 1 |
| registered from | `92.180.230.164` | `192.168.1.2` (Router B's WAN) |

pc2's row records one connection negotiation since the 2026-10-17 restart. It came from
`92.180.231.110`. That is very likely the lenovo: same provider range, and only two peers are
registered. The server sent it over the relay. That is the **fallback** after the direct attempt, and it behaved
correctly. hbbs forces the relay because pc2 registers from a private address and the
controller does not (`rendezvous_server.rs:1467`, `peer_is_lan ^ is_lan`). Hole punching
into pc2 could not work through two NATs anyway.

## 3. Fix — on Router A (yours)

LuCI → **Network → Firewall → Port Forwards**, one rule:

| field | value |
|---|---|
| Protocol | TCP |
| External zone | wan |
| External port | 21666 |
| Internal zone | lan (the 192.168.1.0/24 side) |
| **Internal IP address** | **192.168.1.2** (Router B's WAN) |
| Internal port | 21666 |

Delete any **Traffic Rule** that only opens 21666. Then Save & Apply.

Check it over SSH on Router A. The nat rule must name the destination:

```sh
uci show firewall | grep -B2 -A8 21666
iptables -t nat -S | grep 21666      # must contain: -j DNAT --to-destination 192.168.1.2:21666
```

Router B already forwards `192.168.1.2:21666 → 192.168.0.102:21118`; leave it as it is.

## 4. Verify from outside before any client test

Run this from any machine that is **not** on either network, such as this box or a phone
hotspot:

```powershell
Test-NetConnection -ComputerName 85.126.226.2 -Port 21666     # TcpTestSucceeded : True
```

Better: `scripts/probe-direct-endpoint.py` also checks that the **right machine** answers.
pc2's first frame is its signed id, and the id is readable inside it:

```sh
python3 scripts/probe-direct-endpoint.py 85.126.226.2:21666 352069946
```

| answer | meaning |
|---|---|
| `PEER 352069946 … The direct path is ready.` | done; go to §5 |
| `refused` | Router A is still not forwarding (today's answer) |
| `timeout` | the forward now goes somewhere that drops it: Router B, or pc2's Windows Firewall |
| `closed` / `foreign` | the forward reaches the wrong host or port |

Validated against the lab: the correct peer reads `PEER`, the same forward checked with a
different id reads `foreign`, and refused, timeout and closed each read as such.

## 5. The real test on the lenovo

1. Install **1.4.10** on the lenovo. pc2 can stay on 1.4.9; the direct logic is on the
   connecting side.
2. In the address book, card menu on pc2 → **Direkt verbinden**. This uses the direct path
   only. The relay is not used, and it either connects directly or shows an error with the
   reason.
3. Header shows **Direkt** = done. Then ⋮ → **Aktuelles Protokoll kopieren** and paste the
   `TBFDesk direct:` lines.

### What the log says, per failure (lab-verified 2026-10-18, build 1.4.10)

Every row was reproduced with the real client against a real peer, using an endpoint
published through the dashboard API and "Direkt verbinden" from the address-book card.
The text in the middle column is what follows `TBFDesk direct: <endpoint> unusable (`.

| what sits behind the endpoint | log says | on the real path this means |
|---|---|---|
| nothing listening / a router rejecting the port | `Failed to connect to … (…: connection refused)` | **today's state**: Router A resets 21666 |
| a firewall silently dropping | `… timed out after 2500 ms` | pc2's Windows Firewall, or a router rule that drops |
| a different service (lab: hbbs on 21116) | `the endpoint answered, but not with a TBFDesk handshake (101 bytes) - the forward reaches a different service, not the workstation` | the forward points at the wrong host or port |
| something that accepts and closes (lab: a dead proxy hop) | `the endpoint accepted the connection and closed it without a TBFDesk handshake` | a forward to a host where nothing serves the port |
| **two forwards in series, both right** | `established with 169.254.1.2:21666 in 68 ms, no relay` | **success**; the header shows *Direkt* |

Outside the connect itself:

| situation | log says |
|---|---|
| no endpoint for this id | `no direct endpoint for 91090423: the last policy (issued …) has endpoints for 1 other peer(s) (13301327) but none for 91090423; set 'Reachable at' …` (lab-run). With the poll off it says `the managed policy poll is OFF`; with no policy yet, `has not received a policy` (code paths, not lab-run). That was the lenovo before 2026-10-18. |
| "Always connect via relay" / "Use WebSocket" / a proxy | `endpoint for 91090423 not tried, relay only: 'Always connect via relay' is on for this peer`. **Direkt verbinden** refuses: *Direct connection to 91090423 failed: this client is set to use the relay only (…)*. |

With **Direkt verbinden**, every failure ends in an error dialog with **OK only**: no automatic
retry and no relay. (Before 1.4.10, the relay-only and no-endpoint refusals were retried
automatically and the retry came up over the relay. Found and fixed in this round.)

## 6. What changed in the client for this (1.4.10)

- **"Failed to connect" now says why:** `connection refused`, `timed out after N ms`, or the OS
  error. Before, refused and dropped read identically, and that difference is what located
  Router A.
- **A forward that reaches the wrong thing says so.** A different service, or a host that
  accepts and closes, each get their own message. Before, both read "the peer's key is
  unavailable" or "Reset by the peer", which pointed at key distribution.
- **"Direkt verbinden" failures are final:** they are never retried automatically, so they
  can never end on the relay.
- **A relay-only setting no longer skips the direct endpoint silently.** "Always connect via
  relay", "Use WebSocket" and a proxy each force the relay. Each now logs `endpoint for … not
  tried, relay only: <which setting>`. **Direkt verbinden** with one of them on fails with
  that reason instead of quietly relaying.
- **No endpoint → the reason is logged:** management poll off, no policy received yet, or a
  policy without an endpoint for this id. This is the line that would have shown the lenovo's
  "never polled" state on day one.
- **⋮ → Copy recent log** collects the main log and the session log (start and end, so the
  connection decision survives a long session) with credentials redacted.

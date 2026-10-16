# TBFDesk — Middle-Segment (DMZ) Server Deployment

**Status:** the XCP-ng host moved into the middle segment on **2026-09-04**. Server = **192.168.1.14** (ubuntu24dev VM), public = **85.126.226.2**. Created 2026-09-02 as prep; rewritten 2026-09-04 for the real addresses. Apply script for the VM: [`scripts/vm-apply-server-address.sh`](scripts/vm-apply-server-address.sh).

## Topology

```
Internet 85.126.226.2 ── [Router A, OpenWrt, 192.168.1.1]
                              │  192.168.1.0/24 = middle segment / DMZ
                              ├── XCP-ng host        192.168.1.13
                              ├── ubuntu24dev (VM)   192.168.1.14   hbbs :21115/21116, hbbr :21117, nemo-api :21120 (admin), :21121 (clients)
                              └── [Router B, OpenWrt, WAN 192.168.1.2 / LAN 192.168.0.1]
                                       │  192.168.0.0/24 = office LAN
                                       ├── pc2 (controller / dev box)  192.168.0.102
                                       └── DC (LDAPS, DNS)              192.168.0.151
```

## The plan and the correction (unchanged from 2026-09-02, still true)

*Placing the server between the two routers so hole punching becomes possible and the server can reach the workstation LANs.* The **reach** part is the whole win; the **punch** part is a misconception:

- This fork's hbbs has **no UDP hole-punch** (the UDP punch/hole/local-addr arms are disabled — upstream's reflection fix — and the proto predates `udp_port`/`force_relay`), and it deliberately **forces relay on a WAN↔LAN mismatch** (`rendezvous_server.rs` `peer_is_lan ^ is_lan`).
- So a roaming controller → office workstation is **always relay**, but the relay sits on-path at the office edge: WAN→server is internet, server→workstation is LAN speed. Same-LAN peers connect **direct** (`FetchLocalAddr`).

**Middle-segment server ⇒ on-path relay for WAN sessions + true direct for LAN sessions.** Hole-punch stays a gated, later optimization (bottom of this file).

| Controller | Target | Path hbbs chooses | Relay address handed out |
|---|---|---|---|
| Office LAN (192.168.0.x) | LAN workstation | **direct** (both inside `--mask`) | fallback relay = `--local-ip` (192.168.1.14) |
| DMZ (192.168.1.x) | LAN workstation | direct attempt is **blocked by router B** (DMZ→LAN REJECT) → relay | `--local-ip` |
| Internet | LAN workstation | **relay forced** (`peer_is_lan ^ is_lan`) | controller gets `-r` (85.126.226.2), workstation gets `--local-ip` |
| Internet | Internet (roaming↔roaming) | punch attempt, relay fallback | `-r` |

"LAN" = inside the hbbs `--mask` (`192.168.0.0/16` covers both 192.168.0.x and 192.168.1.x — keep it that way).

## Routing between the office LAN and the DMZ (route, don't NAT)

Router B originally masqueraded the office LAN behind its WAN address and rejected everything from the DMZ. That means double NAT for the office (bad for hbbs, which then sees one IP for every workstation) and no path from the server to the DC. The correct setup:

**Router A (192.168.1.1)** — static route to the office LAN, fixed DMZ addresses:
```sh
uci add dhcp host; uci set dhcp.@host[-1].name='routerB'; uci set dhcp.@host[-1].mac='<router B WAN MAC>'; uci set dhcp.@host[-1].ip='192.168.1.2'
uci add dhcp host; uci set dhcp.@host[-1].name='xcp';     uci set dhcp.@host[-1].mac='<XCP MAC>';          uci set dhcp.@host[-1].ip='192.168.1.13'
uci add dhcp host; uci set dhcp.@host[-1].name='tbfdesk'; uci set dhcp.@host[-1].mac='<VM MAC>';           uci set dhcp.@host[-1].ip='192.168.1.14'
uci add network route
uci set network.@route[-1].interface='lan'
uci set network.@route[-1].target='192.168.0.0/24'
uci set network.@route[-1].gateway='192.168.1.2'
# optional: DMZ DHCP clients learn the direct route (no hairpin via router A for VM→LAN replies)
uci add_list dhcp.lan.dhcp_option='121,192.168.0.0/24,192.168.1.2'
uci commit; /etc/init.d/network restart; /etc/init.d/dnsmasq restart
```

**Router B (192.168.0.1)** — static WAN, masquerade OFF, one DMZ→LAN hole (server → DC LDAPS):
```sh
uci set network.wan.proto='static'; uci set network.wan.ipaddr='192.168.1.2'; uci set network.wan.netmask='255.255.255.0'
uci set network.wan.gateway='192.168.1.1'; uci set network.wan.dns='192.168.1.1'
uci set firewall.@zone[1].masq='0'          # check the index: uci show firewall | grep "name='wan'"
uci add firewall rule
uci set firewall.@rule[-1].name='tbfdesk-server-to-DC-ldaps'
uci set firewall.@rule[-1].src='wan';  uci set firewall.@rule[-1].src_ip='192.168.1.14'
uci set firewall.@rule[-1].dest='lan'; uci set firewall.@rule[-1].dest_ip='192.168.0.151'
uci set firewall.@rule[-1].proto='tcp'; uci set firewall.@rule[-1].dest_port='636'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit; /etc/init.d/network restart; /etc/init.d/firewall restart
```
Keep router B's wan zone at input/forward **REJECT** — once the DMZ is internet-facing this is the defense in depth: a compromised server reaches the DC on 636 and nothing else. Optional (only if the VM should be a *controller* of LAN workstations with a direct path): a second rule `src=wan src_ip=192.168.1.14 dest=lan proto=tcp dest_port=21118` — otherwise those sessions simply relay.

**Port split (2026-10-16).** `:21120` serves the dashboard *and* every admin route, so it is the
port to firewall to the operator's own address. `--nemo-client-api-bind 0.0.0.0:21121` then carries
**only** what clients call (tls-cert-info, login, address book, policy poll, audit, update manifest)
and no admin route at all, so remote clients keep working while the admin surface stays closed.
**Both must be forwarded for a client outside the LAN:** 21116/21117 to connect, **21121** to be
managed. Without the 21121 forward a remote client registers (and appears in Peers) but fails every
poll, login and device-key claim. Same certificate on both binds — clients pin its fingerprint.

**Verify:** on pc2 `tracert 192.168.1.14` (1 hop), `curl -k https://192.168.1.14:21120/nemo/admin`; on the VM `nc -zv 192.168.0.151 636`. Don't use ping from the VM to pc2 as the test — the Windows firewall answers ICMP only from its own subnet, and router B rejects unsolicited DMZ→LAN anyway.

## Two addresses, one server (LAN 192.168.1.14 vs public 85.126.226.2)

hbbs already has the mechanism (upstream issue #24 — `rendezvous_server.rs` lines ~629–634 and ~934–937):

- `-r <relay>` is what **non-LAN** peers are told to use → must be the **public** address: `-r 85.126.226.2:21117`.
- `--local-ip <ip>` is what **LAN** peers (inside `--mask`) are told to use → `--local-ip 192.168.1.14`. (Auto-detected from the default route when omitted; set it explicitly.)
- In the `RelayResponse` fix-up the server string-compares the workstation's chosen relay with `local_ip` and swaps in `-r` for an internet controller. So a workstation's `relay-server` option must be **exactly `192.168.1.14`** (no `:port`) or empty — never `192.168.1.14:21117`.
- The controller side has no override: it connects to whatever relay hbbs delivers (`client.rs create_relay`). The controlled side's own `relay-server` option overrides the delivered one (`rendezvous_mediator.rs get_relay_server`).

hbbs ExecStart (systemd `rustdesk-hbbs-nemo.service` on the VM):
```
hbbs -r 85.126.226.2:21117 --local-ip 192.168.1.14 --mask 192.168.0.0/16 -k _ --nemo-api Y --nemo-api-bind 0.0.0.0:21120 --nemo-client-api-bind 0.0.0.0:21121 --nemo-api-token <token> --nemo-api-tls auto
```
hbbr unchanged (caps lifted to 10 Gbit/s in `rustdesk-hbbr-nemo.service.d/override.conf`).

Two things that are start-time hard failures or silent pairing breaks, not preferences:

- **The API token is mandatory, not advisory.** On a routable `--nemo-api-bind`, hbbs
  exits at startup with *"Refusing to bind Nemo management API to 0.0.0.0:21120 without
  --nemo-api-token"*. Supply it as `NEMO_API_TOKEN=` in `/etc/tbfdesk/hbbs.env`, **never**
  on the command line — argv is world-readable through `/proc` (SEC-11). The shipped unit
  does this already, and hbbs accepts the underscore spelling precisely so an
  `EnvironmentFile` (whose keys cannot contain dashes) suffices on its own.
- **hbbr needs the SAME signing key as hbbs** (`-k _` + the shared `id_ed25519`); both log
  an identical `Key:` line at startup, and a mismatch breaks relay pairing silently. Its
  relay address must also be routable — hbbr treats any loopback connection as its command
  port, so a `127.0.0.1` relay address can never pair.

**Client config split:**

| Client | `custom-rendezvous-server` | `relay-server` | `api-server` / `nemo-management-server` |
|---|---|---|---|
| Office LAN + DMZ (pc2, the VM's own host client `dev` + `gdm`) | `192.168.1.14` | `192.168.1.14` | `https://192.168.1.14:21120` |
| Internet / roaming | `85.126.226.2` | `85.126.226.2` (or empty → hbbs hands out `-r`) | `https://85.126.226.2:21121` |

Locked-exe names for the two cases (the login gate's *Server* field sets the rendezvous + api + management keys from one value; `relay=` in the exe name sets `relay-server`):
- LAN: `rustdesk-host=192.168.1.14,key=XsN4Zx48nKhoIkVgHxPyIqtY07bHa68hW9pMIBv7Ahc=,relay=192.168.1.14,.exe`
- Internet: `rustdesk-host=85.126.226.2,key=XsN4Zx48nKhoIkVgHxPyIqtY07bHa68hW9pMIBv7Ahc=,relay=85.126.226.2,.exe`

**Dashboard → Global client defaults → `api-server`:** leave it EMPTY while LAN and internet clients use different addresses — it is one value pushed to every client and would break whichever side it doesn't match. Set it once a DNS name exists.

**DNS name (the real fix, do it early):** one name, e.g. `tbfdesk.<domain>`, resolving to `192.168.1.14` inside (A record on the DC's DNS; router B forwards LAN DNS to the DC / router A's dnsmasq gets a `host-record` for DMZ hosts) and to `85.126.226.2` outside (public DNS). Then every client, the locked-exe name, `-r` (`-r tbfdesk.<domain>:21117` — resolved per client, so the same split applies to the relay) and the certificate use the same string, and nothing is re-keyed when an address changes. The self-signed nemo-api cert has SANs `localhost` + hostname only (`nemo_management.rs resolve_rustls`), so name-based TLS validation needs a CA-signed cert (`--nemo-api-tls-cert/-key`) or the A4 fingerprint pin (`nemo-api-cert-fingerprint`).

## Internet exposure (router A port forwards → 192.168.1.14 only)

Workstations stay **outbound-only**; nothing is ever forwarded to a workstation. Forward to the server only:

| Ext port | Proto | → 192.168.1.14 | Purpose | When |
|---|---|---|---|---|
| 21115 | TCP | :21115 | hbbs NAT-type test | now |
| 21116 | TCP | :21116 | hbbs rendezvous (TCP punch/relay negotiation) | now |
| 21117 | TCP | :21117 | hbbr relay — the on-path fast path | now |
| 21118 / 21119 | TCP | same | WebSocket clients | only if enabled |
| 21120 | TCP | :21120 | nemo-api: login, policy, address book, **and the admin dashboard** | only with a CA cert or the fingerprint pin enforced AND `allow-insecure-tls-fallback` OFF — until then reach it over WireGuard |

**UDP 21116 is deliberately NOT forwarded.** This row used to say "TCP + UDP"; that has
been wrong since `--udp-registration` landed with a default of `N` (verified in
`rendezvous_server.rs:287`). hbbs *refuses* plaintext UDP registration — that transport
carries no key exchange and no device-key proof, so honouring it would bypass both
`--key-exchange` and `require-device-key`. Clients default to `disable-udp=Y` to match,
and hbbs skips its own UDP self-test (`:401`) because the arm it probes refuses by
design. Forwarding it buys an edge-firewall hole for nothing. Forward UDP only if you
deliberately pass `--udp-registration Y`. Unrelated to UDP hole punching, which is a
separate client switch (`enable-udp-punch`) and is not implemented in this fork at all
(see the bottom of this file).

`21115` and `21118`/`21119` are listed above for completeness but stay unforwarded in
practice: ws rendezvous is not merely unused — `rendezvous_server.rs` refuses that branch
outright, for the same "no key exchange, no device-key proof" reason.

```sh
# router A — one entry per row above (all TCP; see the UDP note below)
uci add firewall redirect; uci set firewall.@redirect[-1].name='tbfdesk-21116-tcp'; uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_dport='21116'; uci set firewall.@redirect[-1].dest='lan'; uci set firewall.@redirect[-1].dest_ip='192.168.1.14'
uci set firewall.@redirect[-1].dest_port='21116'; uci set firewall.@redirect[-1].proto='tcp'; uci set firewall.@redirect[-1].target='DNAT'
```
Leave fw4's default NAT reflection on: a LAN client mis-configured with the public address still works (hairpinned through router A, source rewritten to router A's LAN IP — inside the mask, so hbbs still treats it as LAN).

Admin access from outside (dashboard, XCP-ng, SSH): **WireGuard on router A**, never port forwards. A road-warrior on WireGuard is simply "inside" and gets direct-IP access and LAN discovery too. Before 21120 goes public, also split the admin API from the client API (reverse proxy passing only `/api/*`, or a server-side `/nemo/*` source allowlist — small feature, not built).

## Validate when the topology is up (harness is ready)

Use `e2e/`:
1. `measure-connection.ps1` from a WAN controller → workstation: confirm **path = relay** and measure setup time + RTT + sustained bitrate.
2. From an on-LAN controller → workstation: confirm **path = direct-local**.
3. Compare against `e2e/results/lan-direct-baseline-2026-08-27.md`.
4. Acceptance: relay adds < ~5 ms RTT vs LAN-direct, sustains the codec bitrate, setup < 1.5 s. If the on-path relay misses these, *then* the hole-punch gate opens.

## Only if on-path relay misses targets — the hole-punch task (Phase 1.4, deferred)

Substantial, gated, and probably unnecessary here. Would require: `hbb_common` proto fields `udp_port`/`is_udp`/`force_relay`, re-enabling a hardened `TestNatRequest` UDP arm + `handle_hole_sent` routing in `rendezvous_server.rs` (without reopening the reflection vector upstream closed), making the WAN↔LAN relay-forcing conditional, and flipping the client's `enable-udp-punch` default. Do not start this unless measurements demand it.

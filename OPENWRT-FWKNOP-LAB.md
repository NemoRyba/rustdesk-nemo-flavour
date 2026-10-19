# Port knocking on the edge router: OpenWrt 19.07.1 lab (2026-10-19)

Production router: TP-Link TL-WDR4300 v1 (Atheros AR9344, `mips_24kc`), OpenWrt 19.07.1
r10911-c155900f66, kernel 4.14.167, LuCI git-20.029.45734-adbbd5c.

## The lab

The AR9344 board cannot be emulated. OpenWrt 19.07.1 `malta/be` runs in
`qemu-system-mips -M malta` and has the **same package architecture (`mips_24kc`), the same
kernel version (4.14.167) and the same LuCI build**, so every userspace package (fwknopd,
iptables, firewall, luci-app-*) is byte for byte the one the real router installs. Only the
kmods differ (each target has its own kernel hash).

Driver: `vm/openwrt/owrt-lab.sh` (outside git): `net-up`, `start`, `provision`, `ssh`,
`console`, `lanexec`, `stop`, `net-down`.

```
 "internet" 10.66.0.0/24      router (OpenWrt 19.07.1)        company LAN 192.168.1.0/24
 host 10.66.0.1: hbbs,  ---  eth0 10.66.0.2  [fwknopd]  br-lan 192.168.1.1  ---  workstation
 technician (controller)      eth2: QEMU user NIC, opkg only                     192.168.1.10
                                                                                 (TBFDesk 91090423)
```

## What OpenWrt's own packages offer

19.07.1 feeds (`mips_24kc`): **`fwknopd` 2.6.10-3** (`libc, iptables, libfko, libpcap1`),
`fwknop` (client), `luci-app-fwknopd` + `luci-i18n-fwknopd-de`. **No `knockd`.** fwknop SPA
is also exactly what the TBFDesk client sends (`nemo_direct.rs`, FKO 3.0.0, byte-compatible).

On the stock image `opkg install fwknopd` succeeds: `iptables` and `kmod-ipt-*` are already
installed, so nothing pulls in a kernel module. Installed size 352 KB.

## Results

Configuration (UCI, as LuCI writes it): one access stanza, `SOURCE ANY`, base64 Rijndael +
HMAC keys (`fwknop --key-gen`), `OPEN_PORTS tcp/21218`, `FW_ACCESS_TIMEOUT 30`,
`FORCE_NAT 192.168.1.10 21218`, `ENABLE_IPT_FORWARDING y`, listening on network `wan`. No
static port forward exists: the DNAT to the workstation is created per knocking source.

| test | result |
|---|---|
| connect to 10.66.0.2:21218 before any knock | refused |
| valid knock (host `fwknop`), connect 1 s later | HTTP 200 from the workstation; DNAT + FORWARD rules for `10.66.0.1` only, with expiry |
| after the 30 s window | rules removed, new connections refused |
| replay of a captured SPA packet | refused: "Replay detected" |
| knock with wrong keys | refused: `FKO_ERROR_INVALID_DATA_HMAC_COMPAREFAIL` |
| `/etc/init.d/firewall restart` | fwknopd's jump rules are flushed; the next valid knock re-adds them and works |
| **TBFDesk end to end** (controller usera → 91090423 behind the router) | client: "knock: sent 225 byte SPA … requesting 0.0.0.0,tcp/21218" → "established with 10.66.0.2:21218 in 306 ms, no relay"; target: "direct access from 10.66.0.1", control ticket authorized (0x50) |
| session past the 30 s window | stays up (conntrack); a new connection without a knock is refused |

## Findings that matter for production

1. **Packages only is enough on a stock 19.07.1 image.** The production install error
   (`Required dependency package kernel is not available`, and LuCI showing `iptables` as
   NOT INSTALLED) does not happen on the stock image. It means opkg wanted to install
   `iptables`, which pulls `kmod-ipt-core`, which requires the exact kernel package of the
   official build: `kernel 4.14.167-1-342af9e4f67b3447c53216ab8e3b12a1` (ar71xx) or
   `…-b84a5a29b1d5ae1dc33ccf9ba292ca1d` (ath79). So the production router is most likely
   not running the stock image (a self-built firmware has another kernel hash), or its opkg
   database lacks the iptables entry. Diagnose on the router:
   ```
   cat /etc/openwrt_release
   opkg list-installed | grep -E '^(kernel|iptables|firewall|kmod-ipt-core) '
   which iptables && iptables -L -n | head -3
   cat /etc/opkg/distfeeds.conf; df -h /overlay
   ```
   - kernel hash matches the official one and iptables is installed → `opkg install fwknopd` works as in the lab.
   - iptables works but is missing from opkg's list → `opkg install libfko libpcap1` then
     `opkg install --nodeps fwknopd` (no flash, no kmods needed).
   - kernel hash differs and iptables is truly absent → no package path; see "Next steps".
2. **The LuCI app is broken by the re-spun feed.** The 19.07.1 luci feed now carries
   `luci-app-fwknopd` git-22.115 (2022), which needs `luci-compat`; that clashes with the
   image's 2020 `luci-base`, so the page fails with HTTP 500 "module 'luci.cbi' not found".
   `opkg install luci-compat --force-overwrite` makes it work (lab: page and overview
   render, a Save & Apply keeps every setting), but mixes 2022 files into 2020 LuCI.
   Recommended: configure with UCI over SSH; the knock works without LuCI.
3. **Keep the `keytype` / `hkeytype` options** (`'Base 64 key'`). fwknopd ignores them, but
   without them the LuCI form shows "Normal Key" with empty fields, and saving it would
   overwrite the real keys. `FORCE_NAT` is not in the form and survives a save.
4. **Make the knock port invisible:** the WAN zone's default input policy REJECT answers
   UDP 62201 with ICMP "port unreachable". Set the WAN zone input to DROP.
5. **SSH to 19.07's Dropbear 2019.78:** RSA keys only (ed25519 came with 2020.79), and the
   ssh-rsa host key has to be re-enabled on a current OpenSSH client
   (`-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa`).
6. **One emulated router stalled once** (no answer on any interface, guest idle) shortly
   after the first boot; it did not recur after a reboot (19 min, a full session through it).
   Treated as an emulation artefact; worth watching on the real hardware.

## The open design question: more than one workstation behind a router

`FORCE_NAT` maps an access stanza to ONE internal host:port, and stanzas are told apart by
their keys. TBFDesk distributes ONE knock key pair per controller policy, so with packages
only, one router can gate exactly one workstation per key pair. Options:

- **A. One stanza per workstation, per-target keys** (packages only on the router). Each
  workstation's WAN port gets its own stanza with its own keys and `FORCE_NAT`. Needs a
  small TBFDesk change: knock keys per endpoint entry instead of per controller policy.
- **B. NAT-access SPA from the client** (packages only on the router). fwknop's NAT-access
  message carries the internal `ip,port`; fwknopd with `ENABLE_IPT_FORWARDING` and no
  `FORCE_NAT` DNATs each request to the host it names. One key for all workstations; the
  endpoint entry would carry the internal address. Needs a client change (SPA message
  type 2) and trusts every keyholder with any internal host:port. (From the fwknop
  documentation; not tried in the lab.)
- **C. Static forwards + a fwknopd-gated FORWARD chain** via a firewall include script.
  Packages only, but relies on rule ordering across fw3 reloads; fragile.
- **D. Upgrade the routers** to a supported OpenWrt release (the WDR4300 v1, 8 MB flash /
  128 MB RAM, is an ath79/generic device; check its device page for the newest release
  built for it before flashing), then the same fwknopd setup from a live
  feed; with fw4/nftables use `iptables-nft`. The long-term fix for the EOL router either
  way.

Recommended: A for the current router (smallest change, no router build), D when the routers
are replaced or reflashed.

# Runbook: port knocking on the external router (on premise)

Goal: the direct-access port forward on the external router (TBFExternRouter,
85.126.226.2) is closed to the internet and opens for a few seconds only for a TBFDesk
client that sends a valid knock (fwknop Single Packet Authorization). Everything here was
rehearsed on a virtual copy of this router: [OPENWRT-FWKNOP-LAB.md](OPENWRT-FWKNOP-LAB.md).

Do this **on premise only**: a mistake in the firewall can cut remote access, and the
fallback is the LAN side or the reset button.

## The router (from its own output, 2026-10-19)

| | |
|---|---|
| Model | TP-Link TL-WDR4300 v1 |
| Firmware | OpenWrt 19.07.1 r10911-c155900f66, **stock** (no taints), target `ath79/generic`, arch `mips_24kc` |
| Kernel package (official) | `kernel 4.14.167-1-b84a5a29b1d5ae1dc33ccf9ba292ca1d` |
| Free flash (`/overlay`) | 2.4 MB; fwknopd + libraries need ~350 KB |
| Known problem | opkg's package list is missing the base packages (`kernel`, `iptables`, `firewall`, `kmod-*`) although they are installed and work. This is why `fwknopd` failed with "kernel is not available". Step 3 repairs it. |

## What changes

```
Before:  internet --tcp/21666--> router --static forward--> workstation        (always open)
After:   internet --udp/62201 knock--> router [fwknopd: valid? open 30 s for that source]
         internet --tcp/21666--> router --DNAT only for that source--> workstation
```

- No static forward for the direct port any more. fwknopd creates the DNAT and the
  forward-accept rule per knocking source IP and removes them after 30 s. A running
  session survives the 30 s (conntrack); every new connection knocks again (the TBFDesk
  client does this by itself, 300 ms before connecting).
- Wrong keys, replayed packets and packets older than 2 minutes are ignored.

## Prepare before going on site

1. **Two keys** (base64; Rijndael 32 bytes, HMAC 64 bytes). The router has no tool to make
   them, so generate them on a PC: `fwknop --key-gen` (Linux), or ask Claude to generate
   them. Keep them like passwords. Both the router and the TBFDesk policy get the same pair.
2. **The current forward's values**, needed in step 6. They are read on the router in
   step 5; write them down here:
   - external port (TBFDesk endpoint port): `21666`
   - internal target IP: `__________` (the forward's `dest_ip`)
   - internal target port: `__________` (the forward's `dest_port`)
3. **TBFDesk policy prepared, not yet saved:** Settings → Global defaults (or a named
   device policy that only the technicians' computers use): Knock enabled, knock port
   `62201`, knock key, knock HMAC key. The workstation's endpoint stays
   `85.126.226.2:21666` (no change).
4. **A test client outside the company network** (the lenovo, or a laptop on a phone
   hotspot), so "closed without a knock" can be tested from the internet side.
5. On the laptop you work from: an SSH client. OpenSSH needs two options for this
   router's Dropbear 2019.78 (RSA host key only):
   `ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<router-LAN-IP>`
   and `scp -O ...` (no SFTP server on 19.07).

## On site

### 0. Connect from the LAN side
```
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<router-LAN-IP>
date        # must be correct to the minute (NTP); fwknopd rejects knocks older than 120 s
```

### 1. Backup
```
sysupgrade -b /tmp/backup-$(date +%F).tar.gz
cp /usr/lib/opkg/status /tmp/opkg-status.before
```
On the laptop: `scp -O root@<router-LAN-IP>:/tmp/backup-*.tar.gz .` (also copy
`/tmp/opkg-status.before`). `/tmp` is RAM: copy before any reboot.

### 2. Read-only check
```
grep -c '^Package:' /usr/lib/opkg/status /rom/usr/lib/opkg/status
grep -A2 -E '^Package: (iptables|kernel)$' /usr/lib/opkg/status
```
Expected: about 100 entries in `/rom/...`, fewer in `/usr/lib/opkg/status`, no `iptables`
or `kernel` entry in the second. If it looks different, stop and use the fallback in step 3.

### 3. Repair opkg's package list
Adds back only the entries that are missing, from the firmware's own original copy:
```
cd /usr/lib/opkg
awk 'BEGIN{RS="";ORS="\n\n"} FNR==NR{split($0,a,"\n");have[a[1]]=1;print;next} {split($0,a,"\n");if(!(a[1] in have))print}' status /rom/usr/lib/opkg/status > /tmp/status.merged && cp /tmp/status.merged status
opkg list-installed | grep -E '^(kernel|iptables|firewall|kmod-ipt-core) '
```
Expected: all four listed, `kernel - 4.14.167-1-b84a5a29b1d5ae1dc33ccf9ba292ca1d`.

- Undo: `cp /tmp/opkg-status.before /usr/lib/opkg/status`
- Fallback (if step 2 looked different): skip the repair and in step 4 use
  `opkg install --nodeps libfko libpcap1 fwknopd` instead.

### 4. Install fwknopd
```
opkg update
opkg install fwknopd
fwknopd --version          # fwknopd server 2.6.10
```
Do **not** install `luci-app-fwknopd`: the feed now has a 2022 build that needs a
`luci-compat` clashing with this firmware's LuCI (page error 500). Everything below is
done over SSH.

### 5. Read the current forward
```
uci show firewall | grep -A9 '=redirect'
```
Find the forward whose `src_dport` is `21666`. Note its section (e.g. `firewall.@redirect[2]`),
`dest_ip` and `dest_port` in the table above. **Do not disable it yet.**

### 6. Configure fwknopd
Replace the four placeholders:
```
KEY='<rijndael key base64>'
HMAC='<hmac key base64>'
INTERNAL_IP='<dest_ip from step 5>'
INTERNAL_PORT='<dest_port from step 5>'

uci set fwknopd.@global[0].uci_enabled=1
uci set fwknopd.@network[0].network=wan
uci set fwknopd.@access[0].SOURCE=ANY
uci set fwknopd.@access[0].keytype='Base 64 key'
uci set fwknopd.@access[0].hkeytype='Base 64 key'
uci set fwknopd.@access[0].KEY_BASE64="$KEY"
uci set fwknopd.@access[0].HMAC_KEY_BASE64="$HMAC"
uci set fwknopd.@access[0].OPEN_PORTS='tcp/21666'
uci set fwknopd.@access[0].FW_ACCESS_TIMEOUT=30
uci set fwknopd.@access[0].FORCE_NAT="$INTERNAL_IP $INTERNAL_PORT"
uci set fwknopd.@config[0].ENABLE_IPT_FORWARDING=y
uci -q delete fwknopd.@config[0].ENABLE_NAT_DNS
uci commit fwknopd
/etc/init.d/fwknopd enable
/etc/init.d/fwknopd restart
sleep 2; logread | grep fwknopd | tail -6
```
Expected log: `Sniffing interface: <the WAN device>`, `PCAP filter is: 'udp port 62201'`,
`Starting fwknopd main event loop.`

Notes:
- `OPEN_PORTS` is the port the client asks for: the **external** port, 21666.
  `FORCE_NAT` is where it really goes.
- Keep `keytype` / `hkeytype`: fwknopd ignores them, but they keep a LuCI form (if anyone
  ever installs it) from showing empty key fields and overwriting the keys on save.
- `SOURCE ANY` = any internet address with the right keys. If the technicians have fixed
  addresses, list them instead (`SOURCE 1.2.3.4, 5.6.7.0/24`).

### 7. Switch the knock on in TBFDesk
Save the policy prepared before (knock enabled + keys + port 62201). Clients pick it up
within 30 s. The static forward still exists, so nothing can break yet.

Test from the outside test client: connect to the workstation. On the router:
```
logread | grep fwknopd | tail -4
```
Expected: `SPA Packet from IP: <client's public IP> received with access source match`,
then `Added DNAT rule ... tcp/21666`. The client's session log says
`TBFDesk knock: sent ... byte SPA to 85.126.226.2:62201` and
`TBFDesk direct: established with 85.126.226.2:21666 ..., no relay`.

### 8. Remove the static forward
```
uci set firewall.@redirect[N].enabled=0      # N from step 5
uci commit firewall
/etc/init.d/firewall restart
```
(Disabled, not deleted: re-enabling it is the rollback.) A firewall restart clears
fwknopd's hooks; the next valid knock puts them back, so nothing else is needed.

Test from outside:
1. Without a knock, from the test client: Windows PowerShell
   `Test-NetConnection 85.126.226.2 -Port 21666` (TcpTestSucceeded must be False), Linux
   `nc -vz -w3 85.126.226.2 21666`, or a port-checker website: **must fail**.
2. A TBFDesk direct connection: **must work** ("established ..., no relay").
3. 1 minute later, test 1 again: must fail (the 30 s window is over; the running session
   stays up).

### 9. Hardening (recommended)
- Make the knock port invisible: the WAN zone answers closed ports with "port
  unreachable". `uci set firewall.@zone[1].input=DROP; uci commit firewall;
  /etc/init.d/firewall restart` (check that `@zone[1]` is the `wan` zone first:
  `uci show firewall.@zone[1].name`).
- `/etc/init.d/sysntpd enabled && echo ntp on` (clock right = knocks accepted).

### 10. Reboot test
`reboot`, wait, then repeat the step 8 tests. fwknopd starts with the WAN interface.

## Rollback (any step)

| situation | do |
|---|---|
| direct connections fail after step 8 | `uci set firewall.@redirect[N].enabled=1; uci commit firewall; /etc/init.d/firewall restart` |
| remove fwknopd entirely | `/etc/init.d/fwknopd disable; /etc/init.d/fwknopd stop; opkg remove fwknopd libfko libpcap1` |
| opkg list repair went wrong | `cp /tmp/opkg-status.before /usr/lib/opkg/status` (or from the laptop copy) |
| everything | `sysupgrade -r /tmp/backup-<date>.tar.gz` (copy it back first), then reboot |
| TBFDesk side | switch "Knock enabled" off; clients stop knocking within 30 s |

## Troubleshooting

| symptom | cause / fix |
|---|---|
| no `SPA Packet` line at all | knock not arriving: is UDP 62201 blocked before the router (provider)? Is the policy saved and the client restarted/polled? `logread` shows which interface fwknopd sniffs; it must be the WAN device |
| `HMAC_COMPAREFAIL` / decryption error | keys differ between router and TBFDesk policy (copy/paste, base64 padding) |
| a log line about the SPA timestamp / time difference | router or technician PC clock is off by more than 2 minutes; check `date` and NTP |
| `Replay detected` | the same packet twice; normal for a resend, harmless |
| knock accepted, connection still fails | `FORCE_NAT` target wrong (step 5 values), or a second router behind needs its own forward to the workstation |
| works, then fails after a firewall restart | the next knock repairs it; a session that was open keeps running |
| only one workstation can be gated | known limit: one key pair maps to one internal target (see OPENWRT-FWKNOP-LAB.md, "more than one workstation"); a second workstation needs a second stanza with its own keys and a TBFDesk change |

## Rehearsal

The same steps can be practised on the virtual router: `vm/openwrt/owrt-lab.sh net-up`,
`start`, `provision` (see the lab doc; the lab's opkg list is healthy, so step 3 is
reproduced there by deleting the entries first).

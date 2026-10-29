# TBFDesk 1.4.18 (Windows + Linux client) and server 1.1.16 — 2026-10-29

## New: the Peers panel shows the policy each client actually applied
Until now the Policy column showed only what the server *assigns*. A client that refused its
policy (rollback/replay protection, bad signature, …) looked exactly like a healthy one.
Every client now reports, on its regular 30-second check-in, which policy it applied — or that
it refused one, and why — plus the names of settings the user changed where the policy allows it.
- **Policy column:** ✓ applied · … pending · ✗ refused · stale (no report for 2 min)
- **Peer detail → Applied policy:** the policy in effect (device / user / default / admin
  policy), the refusal reason, locally overridden settings (names only, never values), for the
  machine's service and for the signed-in user's window separately.
- **Encrypted and signed like everything else:** the report travels inside the client's
  check-in, which is sealed to the server's management key, and carries its own device-key
  signature. Unsigned or malformed reports are ignored.
- Needs **server 1.1.16 and client 1.4.18**. Older clients keep working and show "not reported".

## Server 1.1.16: an installer that upgrades safely
The 1.1.15 `install.sh` put the binaries in `/usr/local/bin` while the service ran
`/usr/bin/hbbs` (an upgrade silently kept the old binary), and it replaced the systemd unit,
which dropped `--nemo-client-api-bind` and took the **client port 21121** down. The new one:
- keeps each unit's `ExecStart` pointed at the freshly installed binary — **no re-pointing
  after updates**;
- edits existing units in place, so your customisations survive;
- never touches an existing `/etc/tbfdesk/hbbs.env`; on a first install it writes a template
  that includes `NEMO_CLIENT_API_BIND=0.0.0.0:21121`;
- `RESTART=1 ./install.sh` installs and restarts in one go.

**Split ports (admin GUI on 21120, clients on 21121):** if 21121 is not listening
(`ss -tlnp | grep 2112`), add `NEMO_CLIENT_API_BIND=0.0.0.0:21121` to `/etc/tbfdesk/hbbs.env`
and restart hbbs. hbbs reads every flag from that file, so this survives future upgrades.

## Linux client
- 1.4.18 packages carry the main-window fix from 1.4.17 (the "…" menu and the status display).
- The **Arch package now contains an Arch build** — the 1.4.16 one contained the Ubuntu binary
  and failed to start on Arch (`libvpx.so.9: cannot open shared object file`).

## Tested
`tests/run-all.sh` — a new automated suite — passed on these exact builds: server and client
unit tests, a client/server contract check, the UI build pipeline, real libsciter parsing, the
server installer in a clean Ubuntu container (fresh install, upgrade over a customised unit,
idempotency), and GUI tests that click through the client (registration, "…" menu, Settings,
logs) on Linux and on Windows 11 with this installer, plus the applied-policy feature end to end.

## Install / upgrade
- **Windows:** `tbfdesk-1.4.18-x64-install.exe` (double-click, or `--silent-install` from an
  elevated prompt) — upgrades in place, keeps ID, device key and settings.
- **Debian/Ubuntu:** `sudo apt install ./tbfdesk-1.4.18-amd64.deb`
- **Arch:** `sudo pacman -U tbfdesk-1.4.18-x86_64.pkg.tar.zst`
- **Server:** unpack `tbfdesk-server-1.1.16-linux-x86_64.tar.gz`, then `RESTART=1 ./install.sh`.
  Upgrade the server first, then the clients.

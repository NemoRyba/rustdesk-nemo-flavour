# TBFDesk — step-by-step deployment (for you, not the LLM)

Read this before `DEPLOY.md` (which has the full detail and rationale). This is the
short, ordered version, updated 2026-09-28 after the day's security fixes.

**Verdict:** lab / internal test run — yes, with the steps below. Production — not yet;
see "Not ready for production" at the end.

---

## 0. What changed today that affects deployment

- A missing `id_ed25519` now **stops hbbs and hbbr** instead of silently minting a new
  key. First install: run hbbs once with `--generate-key Y`, then drop the flag forever.
- A fresh install now has `require_device_key` **ON** by default (it used to be off).
  You must provision at least one device key, or switch it off temporarily, before any
  client can connect.
- `require_sealed_login` is now **ON** by default too. Current clients always seal their
  login, so this changes nothing for you — it only matters if some third-party/old
  client ever talks to this server.
- The server now pushes its own TLS certificate's fingerprint to every client
  automatically, so "accept any certificate" turns itself off after the first policy
  poll. Back up `nemo-api-cert.pem` / `nemo-api-key.pem` — if you ever regenerate that
  certificate, every already-pinned client is locked out until you clear the pin on it.
- Port-forwarding (and RDP-over-port-forward) is now actually encrypted end to end.
  **Every workstation and every technician client must be upgraded together** — an old
  client talking to a new server (or the reverse) will fail to port-forward.
- No connection to rustdesk.com anywhere, any more, by decision — the daily version
  check, the client's fallback to RustDesk's own server when nothing is configured, and
  two reachable UI links (a "set up your own server" tip, the installer's EULA link)
  are all gone. Nothing to configure for this; it only matters if you were relying on
  the old behavior for something (you shouldn't have been).
- A management policy response with no `issued_ts` stamp is now refused outright — no
  backward compatibility with a server predating anti-rollback protection. Only matters
  if you somehow reintroduce such a server into the fleet, which is not supported.

---

## 1. Build

On the build machine (Linux, this repo):

```bash
cd rustdesk-server-nemo
cargo build --release          # produces target/release/hbbs and target/release/hbbr
cargo test                     # expect "82 passed" or more, 0 failed, on every line
```

For the Windows client, follow `DEPLOY.md` section 2 (needs a Windows build host).
For a Linux technician client:

```bash
cd rustdesk-client-nemo
cargo build --release --features linux-pkg-config,hwcodec
cargo test --release --features linux-pkg-config,hwcodec --lib   # expect "86 passed" or more
```

## 2. Server host: install the binaries and the signing key

```bash
useradd --system --home /var/lib/rustdesk-server --shell /usr/sbin/nologin rustdesk
install -d -o rustdesk -g rustdesk -m 0750 /var/lib/rustdesk-server /var/log/rustdesk-server
install -m 0755 rustdesk-server-nemo/target/release/hbbs rustdesk-server-nemo/target/release/hbbr /usr/bin/
```

**The signing key.** Every client that is ever provisioned pins this key. Losing it or
replacing it silently means re-provisioning your whole fleet.

- If you have a key from a previous install: put it at
  `/var/lib/rustdesk-server/id_ed25519`, mode 0600, owner `rustdesk`. **Back it up
  somewhere else too.**
- If this is the very first install (no key exists anywhere): run hbbs once, by hand, as
  the `rustdesk` user, with `--generate-key Y`:
  ```bash
  sudo -u rustdesk sh -c 'cd /var/lib/rustdesk-server && /usr/bin/hbbs -k _ --generate-key Y -p 21116'
  # Ctrl+C once you see "Key: ..." printed — you don't need it actually serving yet.
  ```
  Back up the resulting `id_ed25519` immediately. Never pass `--generate-key Y` again
  after this — the systemd unit below does not, on purpose.

## 3. systemd units and firewall

Install `rustdesk-server-nemo/systemd/rustdesk-hbbs-nemo.service` and
`rustdesk-hbbr-nemo.service`. Fill in `/etc/tbfdesk/hbbs.env` per `DEPLOY.md` section
"Server" (admin token, relay address, LAN mask). Then:

```bash
systemctl enable --now rustdesk-hbbs-nemo rustdesk-hbbr-nemo
journalctl -u rustdesk-hbbs-nemo -n 30    # look for "Key: <same key as id_ed25519.pub>"
journalctl -u rustdesk-hbbr-nemo -n 30    # same key, must match hbbs's line exactly
```

Firewall, lab/internal subnet only:

- allow TCP 21115, 21116, 21117 (rendezvous + relay)
- allow TCP 21120 (management API / admin dashboard)
- block 21114, 21118, 21119 — nothing listens behind them for a real client

## 4. First admin login and provisioning

1. Open `https://<server>:21120/nemo/admin` (self-signed cert warning is expected on the
   very first visit — that is what the fingerprint push in step 0 then fixes for every
   client after their first policy poll).
2. Check the **setup string** fields under *Settings → Device keys*. There are **two**
   blocks, because this server has two addresses and a client carries only one set:
   - **Inside the network (LAN)** — prefilled from the address you are reading the
     dashboard on, else `--local-ip`; its relay is the LAN address, so an internal
     session does not hairpin out through the router and back.
   - **From the internet (public)** — prefilled from the server's `-r` address, and
     never from the dashboard address. If hbbs was started without `-r`, this block is
     empty and asks you to fill it in; that is deliberate, because the alternative is a
     LAN address inside the "from the internet" string.

   Fix both here, once, before you hand anything out. For the lab topology the values are
   in `TOPOLOGY-DEPLOYMENT.md`'s client-config table (LAN `192.168.1.14`, internet
   `85.126.226.2`); the lasting fix for a laptop that is on both sides is the
   split-horizon DNS name recommended there, which makes the two strings identical.
3. For each workstation: **Device keys → generate one** (bind it to the workstation's id
   if it already has one; leave the id empty to use first-use claiming, see
   `DEVICE-KEY-CLAIM.md`). The result includes **both setup strings** — that key *plus*
   the six server values a fresh client cannot reach the server without, once for each
   side of the network. **Copy** or **Download file** the one that matches where that
   machine connects from (`…-lan…` vs `…-wan…` in the file name); handing over the wrong
   one fails like a network fault.
4. On the workstation: client → *Import device key* → paste the setup string, or
   **Load from file…** and pick the downloaded `.tbfsetup`. One paste and the machine is
   configured and keyed; nothing else is typed in by hand. Unattended instead:
   `tbfdesk --import-setup <file|string>`, which prints what it changed.
   The dialog accepts a bare device key just as it did before, so a machine that is
   already configured needs nothing new.
5. Once every real workstation has a bound key, switch `require_device_key` back **on**
   (it is on by default; if you turned it off to get a first machine registered, this is
   where it goes back).
6. If you use LDAP login, configure it under Integration, then set `require_login` on
   once the allowlist is populated (see `DEPLOY.md` "Integration").

## 5. Verify before you call it done

- `curl -sk -H 'Authorization: Bearer <token>' https://127.0.0.1:21120/nemo/api/health`
  — should show `require_device_key: true`, `require_sealed_login: true`.
- Connect from an actual technician client to an actual workstation; confirm the
  password/device-key gate is enforced (a machine without a bound key must be refused
  once `require_device_key` is back on).
- If you use port-forwarding or RDP-over-tunnel: confirm every workstation and every
  technician client is on this same build. Mixing an old and a new build will fail the
  tunnel, not silently downgrade it to plaintext.

## 6. Backups and upgrades

Back up, on every change and before every upgrade:
`id_ed25519`, `nemo-api-cert.pem`, `nemo-api-key.pem`, `nemo_integration.json`,
`nemo_sessions.json`.

Upgrade server and every client together — see `DEPLOY.md` section 5 ("Upgrading") for
exactly what breaks if you don't.

---

## Not ready for production yet

Independent of today's fixes, these are still open (see
`/projects/rustdesk/OPEN-POINTS-2026-09-21.md` for the full, current list):

- No automatic backup or crash-safe upgrade/rollback procedure beyond "copy these
  files first" above.
- The management API's TLS is self-signed by default; for a real deployment, supply a
  CA-issued certificate (`--nemo-api-tls-cert` / `--nemo-api-tls-key`) rather than
  relying on the pinning fallback.
- Provisioning a device key is a manual, one-machine-at-a-time dashboard step — there is
  no bulk/scripted provisioning path yet.
- The Windows packaging script has not been run end to end in this environment.

Use this for a lab or internal pilot; do not expose the management API or the rendezvous
ports directly to the internet without also reading `TOPOLOGY-DEPLOYMENT.md`.

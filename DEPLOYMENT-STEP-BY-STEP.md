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
- The management API is hardened against abuse: a per-source rate limit sheds floods on the
  unauthenticated routes before any work (C1); every `/nemo/api/*` admin route checks the token
  before parsing the body (C3); and `/nemo/admin` has a new **Security panel** listing
  auto-blocked source IPs, rate-limited sources and accounts under login backoff, with one-click
  Unblock/Reset/Clear (C4). On with the API — nothing to configure. (Pentest: no break found;
  see `SECURITY-VERIFICATION.md` / `pentest/`.)
- A **selective uninstaller** now ships with both client and server
  (`rustdesk-client-nemo/res/uninstall/`, `rustdesk-server-nemo/scripts/uninstall/`): a GUI
  checklist (or headless mode) to remove an install and optionally wipe settings, the device ID +
  keypair, the device key/secrets and — for the server — the signing keys, DB and policy state.
  `tbfdesk-uninstall.sh server` + `hbbs -k _ --generate-key Y` = a clean teardown and a fresh
  server with new keys (all provisioned clients must then be re-provisioned).
- Versioned **installers** are published as GitHub releases — `release-2026-10-29c`: Windows
  client 1.4.19 `.exe`; `release-2026-10-29b`: Linux client 1.4.18 (Debian/Ubuntu `.deb`, Arch
  `.pkg.tar.zst`, a generic Linux client tarball) and server 1.1.16 — each with a `.sha256`. They
  are **not code-signed** (SmartScreen / "unknown publisher"); check the `.sha256`.

**Since 2026-10-28:**

- **Server 1.1.16 `install.sh` is upgrade-safe** (`RESTART=1 ./install.sh`): units keep pointing at
  the binary it installs, existing units are edited in place, `/etc/tbfdesk/hbbs.env` is never
  overwritten. If clients use the split port 21121, `NEMO_CLIENT_API_BIND=0.0.0.0:21121` must be
  in that env file — the 1.1.15 installer dropped it (OPEN-TODOS #46).
- **Peers panel shows the policy each client actually applied** (server 1.1.16 + client 1.4.18).
- **Windows 1.4.19 (`release-2026-10-29c`): install and provision in one silent call** —
  step 4 below. The uninstallers now also remove the old `RustDesk` config folders, which a
  reinstall used to import again (old ID, keypair, device key).
- **Roaming profiles:** opening the client window copies the device key and the machine's
  keypair into `%APPDATA%\TBFDesk\config` (OPEN-TODOS #48, every version). Exclude
  `AppData\Roaming\TBFDesk` from roaming by GPO — `DEPLOY.md` §4.

---

## 1. Build

On the build machine (Linux, this repo):

```bash
cd rustdesk-server-nemo
cargo build --release          # produces target/release/hbbs and target/release/hbbr
cargo test                     # expect "125 passed" or more, 0 failed, on every line
```

Or skip the build: the release tarball `tbfdesk-server-<version>-linux-x86_64.tar.gz` carries
`hbbs`, `hbbr` and `install.sh` (step 2).

For the Windows client, follow `DEPLOY.md` section 2 (needs a Windows build host).
For a Linux technician client (Arch; `scripts/build-arch-client.sh` sets the compiler and
library paths):

```bash
cd rustdesk-client-nemo
cargo build --release --features inline,linux-pkg-config,hwcodec   # inline: the UI is embedded
cargo test --release --features linux-pkg-config,hwcodec --lib     # expect "134 passed" or more
```

The whole suite, including GUI clicks on Linux and the Windows VM: `tests/run-all.sh`
(`tests/README.md`).

## 2. Server host: install the binaries and the signing key

**From the release tarball (1.1.16+):** unpack it, then `./install.sh`. It installs `hbbs`/`hbbr`
to `/usr/bin`, creates the `rustdesk` user and `/var/lib/rustdesk-server` +
`/var/log/rustdesk-server` if missing, installs or updates the two systemd units, and on a first
install writes an `/etc/tbfdesk/hbbs.env` template (an existing one is never touched). For an
upgrade: `RESTART=1 ./install.sh`. Then continue with *The signing key* below.

**By hand, from your own build:**

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
- with the split client port (dashboard internal-only, clients on 21121 —
  `TOPOLOGY-DEPLOYMENT.md`): allow TCP 21121, and put `NEMO_CLIENT_API_BIND=0.0.0.0:21121` in
  `/etc/tbfdesk/hbbs.env` (not in the unit, so upgrades keep it). Check with
  `ss -tlnp | grep 2112`.
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
   configured and keyed; nothing else is typed in by hand. **Unattended instead (Windows,
   1.4.19+), no GUI at all** — install and provision in one call:
   ```powershell
   $p = Start-Process .\tbfdesk-1.4.19-x64-install.exe -PassThru `
          -ArgumentList '--silent-install', '--import-setup', 'C:\deploy\pc1.tbfsetup'
   $null = $p.Handle; $p.WaitForExit(); $p.ExitCode   # 0 done · 1 failed · 2 bad setup value
   ```
   or, on a client that is already installed, from a pipe:
   `Get-Content pc1.tbfsetup | & 'C:\Program Files\TBFDesk\TBFDesk.exe' --import-setup - | Out-String`.
   Both print what they set (never the key). Delete the `.tbfsetup` afterwards — it holds the
   device key. Details and exit codes: `DEPLOY.md` §4.
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

**Resetting one Windows client's settings** (re-provisioning a machine, or clearing a
botched import): `scripts/reset-windows-client-config.ps1`, elevated. It stops the
service, backs up and deletes the `*.toml` in **both** config directories — the signed-in
user's `%APPDATA%\TBFDesk\config` and the service's own copy under
`C:\Windows\ServiceProfiles\LocalService\…`, which is the one people miss, plus the pre-rename
`RustDesk` directories of both — then starts the service again. To re-provision without
resetting the ID, pipe a new setup file into the installed client instead
(`DEPLOY.md` §4, 1.4.19+).

Three consequences, all intended: the machine loses its **device key** and server
settings (import a setup string again), it comes back with a **new TBFDesk ID**, so the
old key on the server is bound to an ID that no longer exists (clear or re-point its
*Bound to ID*, or delete it and issue a new one), and the `.bak` files the script leaves
behind **still contain the device key** — fine for a repair, delete them for a
decommission. For a full removal use the uninstaller (`tbfdesk-uninstall.ps1` /
`tbfdesk-uninstall.sh`, on every release), which can wipe the ID, keypair and device key too;
every leftover path and registry key is listed in the client repo's
`docs/nemo-provisioning.md`.

---

## Not ready for production yet

Still open as of 2026-10-29 (the full list with status: `OPEN-TODOS.md`):

- No automatic backup or crash-safe upgrade/rollback procedure beyond "copy these
  files first" above. (Since 1.1.16 the server `install.sh` at least upgrades in place
  without losing the units' settings or `hbbs.env`.)
- The management API's TLS is self-signed by default; for a real deployment, supply a
  CA-issued certificate (`--nemo-api-tls-cert` / `--nemo-api-tls-key`) rather than
  relying on the pinning fallback.
- Device keys are still **issued** one machine at a time (dashboard, or the admin API
  `POST /nemo/api/device-keys`). **Applying** one is scriptable on Windows since 1.4.19
  (`--silent-install --import-setup`, step 4); Linux still takes a
  `sudo rustdesk --import-setup` per machine (OPEN-TODOS #47).
- **Roaming profiles receive the machine's secrets** once the client window opens
  (OPEN-TODOS #48) — exclude `AppData\Roaming\TBFDesk` from roaming by GPO until it is fixed.
- The installers are **not code-signed** (`DEPLOY.md` §2 *Signing*).
- The Debian/Ubuntu `.deb` is VP8/VP9/AV1 only — **no hwcodec H.264/H.265** (Windows, the Arch
  package and the generic tarball have it); OPEN-TODOS #42.
- ~~The Windows packaging script has not been run end to end~~ — done: Windows installers built
  on the VM and published since 1.4.16 (`release-2026-10-26`), latest 1.4.19
  (`release-2026-10-29c`).

Use this for a lab or internal pilot; do not expose the management API or the rendezvous
ports directly to the internet without also reading `TOPOLOGY-DEPLOYMENT.md`.

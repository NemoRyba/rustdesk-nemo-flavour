# TBFDesk server 1.1.18 — 2026-11-17

Server commit `e6a1c13` (branch `nemo-tdd`); the dashboard shows build `e6a1c13 2026-11-17`.
Clients unchanged (1.4.21 / 1.4.22 Linux hotfix work with it).

## Files
- `tbfdesk-server-1.1.18-install.run` — installer/updater (one file)
- `tbfdesk-server-1.1.18-linux-x86_64.tar.gz` — the same release as a tarball
- `.sha256` for each, plus `SHA256SUMS`

## Update an existing server (keeps configuration, identity, database)
```
sudo ./tbfdesk-server-1.1.18-install.run --update     # unattended
sudo ./tbfdesk-server-1.1.18-install.run --text       # menu in the terminal (no GUI dialog)
```
A backup of everything is written to `/var/backups/tbfdesk/` first.

## Changes
- **Installer shows what it is doing.** Before asking for administrator rights it says so (and
  where the password dialog is, with the `sudo` fallback); then `-> Backing up / Installing /
  Verifying services` progress lines. `--help` lists `--text` (menu in the terminal) and `--fresh`.
- **Fresh install works out of the box.** A new install now creates the server identity key; before,
  the service restarted endlessly until the key was created by hand.
- **"New version live: NO" false alarm fixed** (systems where the running binary cannot be read).
- **Eye button on every password field** in the dashboard.
- **Stored passwords can be recalled — audited.** Clicking the eye on a saved password/key fetches
  that one value from the server; each reveal is written to the dashboard **Log** (which secret,
  where, from which address — never the value).
- **Security: named policies, users' policies and the admin policy no longer send their stored
  passwords to the browser** (only global/per-device policies were masked before). Saving a page
  keeps the stored values.

## Tested
Systemd test machine: fresh install (services up, 0 restarts); 1.1.17 -> 1.1.18 `--update` with
identity/config/database unchanged; `--text` menu; masked responses + page round trip keeps the
password; reveal (audited, no-store, 400/401 for wrong key / no token); the eye clicked in Firefox.

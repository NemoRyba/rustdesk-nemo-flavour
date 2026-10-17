# TBFDesk 1.4.8 — Windows x64

| | |
|---|---|
| file | `tbfdesk-1.4.8-x64-install.exe` (17.2 MiB) |
| sha256 | `6e43fe78c9bbfc1fc47710a1e8ba2be203226a73983c50b1b233ac6691160054` |
| tag | `tbfdesk-win-1.4.8` (client `028a76c39`, hbb_common `40b4e27`) |
| built | in the test VM, `--features inline,hwcodec`, x64 |
| signed | **no** — SmartScreen will warn and UAC will say "unknown publisher" |

Install: double-click it, or `tbfdesk-1.4.8-x64-install.exe --silent-install` for GPO/RMM.
**It upgrades a 1.4.7 install in place and keeps the machine's identity** — see below.

## The app is called TBFDesk now, all the way down

1.4.7 was TBFDesk everywhere a *person* looks inside the app, but the operating system
still said RustDesk: `C:\Program Files\RustDesk`, `%APPDATA%\RustDesk`, the `RustDesk`
service, the `RustDesk` uninstall key, `rustdesk://`. That is fixed:

| | 1.4.7 | 1.4.8 |
|---|---|---|
| install directory | `C:\Program Files\RustDesk` | `C:\Program Files\TBFDesk` |
| executable | `rustdesk.exe` | `tbfdesk.exe` |
| service | `RustDesk` / "RustDesk Service" | `TBFDesk` / "TBFDesk Service" |
| Apps & features key | `…\Uninstall\RustDesk` | `…\Uninstall\TBFDesk` |
| settings | `%APPDATA%\RustDesk` | `%APPDATA%\TBFDesk` |
| config files | `RustDesk.toml`, `RustDesk2.toml` | `TBFDesk.toml`, `TBFDesk2.toml` |
| URI scheme | `rustdesk://` | `tbfdesk://` |

### Upgrading does not cost a machine its identity

This is the part that had to be right. The ID, the permanent password, the device key and
every setting are carried over to the new location on first start — including the Windows
service's own copy, under its service profile. The old directory is left where it is, as a
rollback copy, so installing a 1.4.7 build over the top still finds it.

The old service, uninstall entry, file association, URI scheme, firewall rules, shortcuts
and install directory are removed, so a machine is not left with two half-working entries.

**Verified on Windows 11 by upgrading a real 1.4.7 install** that had a registered ID, an
approved device key, a running service and a signed-in user:

- ID **12513041** before and after, out of the new `%APPDATA%\TBFDesk\config\TBFDesk.toml`;
- the server saw the same peer re-register and **re-prove its device key** seconds after
  the upgrade — the binding is to the peer id, so a changed ID would have broken it;
- server key, management key, certificate pin, device key and the managed-poll switch all
  byte-identical in the new location;
- the service runs as `TBFDesk` from `C:\Program Files\TBFDesk`, the old one is gone;
- `…\Uninstall\RustDesk`, `HKCR\rustdesk`, `HKCR\.rustdesk`, the "RustDesk Service"
  firewall rules and `C:\Program Files\RustDesk` are all gone;
- desktop, Start-menu and Startup shortcuts point at `C:\Program Files\TBFDesk\tbfdesk.exe`;
- the client came up still signed in, with the address book populated.

### Also in this build

- **The tab labels fit.** An installed client shows four tabs, and the old code shared the
  row's width out by character count with a hard limit — so as soon as the German labels
  did not fit it truncated **all four** ("Letzte Sitz… / Favor… / Im LAN e… / Adres…").
  The row now wraps to a second line and every label stays whole.
- The AGPL attribution can no longer be rewritten into the app's own name by the
  translation layer.

## Known: Linux packaging still says rustdesk

On Linux the *package* — the binary, `rustdesk.service`, `rustdesk.desktop`,
`/etc/rustdesk/` — is unchanged by design (RENAMING-PLAN Layer 3). The Linux config
directory does move, to `~/.config/tbfdesk`, with the same migration. No Linux package is
built from this tree today.

## Publishing

```bash
gh release create tbfdesk-win-1.4.8 \
  --repo NemoRyba/rustdesk-client-nemo \
  --title "TBFDesk 1.4.8 — Windows x64" \
  --notes-file dist/RELEASE-NOTES-1.4.8.md \
  dist/tbfdesk-1.4.8-x64-install.exe dist/tbfdesk-1.4.8-x64-install.exe.sha256
```

To push it to the fleet instead (the fork's own signed updater), POST the file and that
sha256 to `/nemo/api/update` on the live server — that makes every client offer the
update, so it is a deliberate, separate decision. **Read the upgrade section above first:**
this update moves the install directory and replaces the service on every machine it
reaches.

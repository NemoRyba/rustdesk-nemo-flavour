# TBFDesk 1.4.7 — Windows x64

> **Superseded by 1.4.8** ([RELEASE-NOTES-1.4.8.md](RELEASE-NOTES-1.4.8.md)), which carries
> everything below **plus** the rename: the install directory, the exe, the service, the
> registry key, `%APPDATA%` and the URI scheme all read TBFDesk, and an existing install is
> migrated rather than orphaned. 1.4.7 was built and verified but never published; ship
> 1.4.8 instead.

| | |
|---|---|
| file | `tbfdesk-1.4.7-x64-install.exe` (17.2 MiB) |
| sha256 | `3c8a38b228c25206f7962a4ff4aca5af06c6118c7a9446b7131a05bd0d30558b` |
| tag | `tbfdesk-win-2026-10-17` (client `83d505e2b`) |
| built | in the test VM, `--features inline,hwcodec`, x64 |
| signed | **no** — SmartScreen will warn and UAC will say "unknown publisher" |

Install: double-click it, or `tbfdesk-1.4.7-x64-install.exe --silent-install` for GPO/RMM.

## What this fixes

Everything below was reported from the field and is fixed and verified on Windows 11:

- **A setup string applies all of itself.** It used to import the ID server and nothing
  else. Every value is written, read back and confirmed; anything that would not store is
  reported with its reason instead of being dropped silently. It also switches the managed
  policy poll on — without which a client was configured for the fleet and talked to
  nobody (no policy, no login gate, no address book, no direct endpoints, no audit).
- **Signing in works again.** The login and address-book requests were failing *before*
  they reached the network, because the header shape the UI sends hit a JSON-only parser.
  No token meant no address book, on every client.
- **Direct connections are visible and selectable.** Peers the server published an
  endpoint for carry a green ⇄ badge in the address book, and their menu gains
  "Direkt verbinden (ohne Relay) — host:port", which uses the forward or tells you why it
  could not, instead of quietly relaying.
- **The first-run screens fit.** The provisioning gate's button no longer runs off the
  window, the import dialog's label is no longer clipped mid-word, and the certificate pin
  no longer overflows the summary.

Server side (deploy `hbbs` 94c12b7 with it): the Peers panel says *why* a machine has not
polled instead of "provisioned, not polled", the Relayed-bytes panel tells "the relay
carried nothing" apart from "we cannot see the relay", **Cut** no longer blocks the peer,
and a device-key claim can actually be approved from the dashboard.

## Verified on Windows 11, with the settings wiped first

First-run gate → **Ctrl+V** of the setup string → every value applied → device-key claim
approved in the dashboard → LDAP sign-in → address book populated with the direct-access
badge → installed with this installer: Start menu, desktop shortcut, Apps & Features entry
and the exe's version info all read **TBFDesk**, the service runs, and the peer shows
online with `auth = device-key`.

## Publishing this as a GitHub release

No GitHub token is configured on the build box, so the tag is pushed and the artifact is
here, unpublished. With a token:

```bash
gh release create tbfdesk-win-2026-10-17 \
  --repo NemoRyba/rustdesk-client-nemo \
  --title "TBFDesk 1.4.7 — Windows x64" \
  --notes-file dist/RELEASE-NOTES-1.4.7.md \
  dist/tbfdesk-1.4.7-x64-install.exe dist/tbfdesk-1.4.7-x64-install.exe.sha256
```

To push it to the fleet instead (the fork's own signed updater), POST the file and that
sha256 to `/nemo/api/update` on the live server — that makes every client offer the
update, so it is a deliberate, separate decision.

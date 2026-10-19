# Lab verification 2026-10-19: client 1.4.14 / 1.4.15, server 2608fec / 7ac7b75

Client `rustdesk-client-nemo` `1217230c1`..`835d014f2` (1.4.14), hbb_common `f188505`,
server `2608fec`. lab2 harness: host hbbs with LDAP, the target `91090423` on Xvnc :41
(Linux, three screens), the controller `449533173` in a container on Xvnc :42 (Linux), and
the Win11 VM `12513041` as a second controller (1.4.12 for the "before" picture, then
1.4.14). Direct endpoint `169.254.1.2:21218` (container) or `10.0.2.2:21218` (VM).

## Session authorization (control tickets)

LDAP users and their rules in the dashboard:

| user | may control | policy |
|---|---|---|
| usera | 91090423 | no clipboard, no file transfer |
| userb | 91090423 | clipboard and file transfer allowed |
| marek | everything (admin) | admin policy |

| # | scenario | target log | result |
|---|---|---|---|
| 1 | usera, direct session | `session authorization: 449533173 as user 'usera' with permissions 0x50` | typed keys arrive; a clipboard marker served on the controller does **not** arrive |
| 2 | usera, file transfer | same | "Keine Berechtigung für die Dateiübertragung", before the password prompt |
| 3 | userb, direct session | `… 'userb' with permissions 0xa0` | clipboard marker arrives; file transfer opens |
| 4 | marek, direct session | `… 'marek' (admin) with permissions 0x22aaaaa` | clipboard arrives |
| 5 | usera restricted to another machine, connects to 91090423 directly, enforcement **off** | `not accepted: user 'usera' is not permitted to control this computer` | refused: "Not authorized: …" |
| 6 | Windows 1.4.14 as usera, file transfer, direct | `session authorization: 12513041 as user 'usera' with permissions 0x50` | refused for file transfer, as on Linux |
| 7 | Windows **1.4.12** as usera, enforcement **off** | no authorization line | **file transfer opens: the bypass the operator reported** |
| 8 | Windows **1.4.12**, enforcement **on** | `session from 12513041 refused: no management authorization` | "This computer only accepts sessions authorized by your TBFDesk server…" |
| 9 | Windows 1.4.14, enforcement **on**, remote session | `… 'usera' with permissions 0x50` | session up, "Direkt" badge |

A typed raw IP (`169.254.1.2:21218`) never reaches the login at all: the controller cannot
anchor the key of a peer it only knows by address and fails closed (existing behaviour).

Windows detail found by test 6's preparation: the SYSTEM `--server` process polls without
the user's token and feeds the session processes' config, so the ticket now lives in the
OS user's LocalConfig (`nemo-user-control-ticket`). Checked on the VM: the UI process
writes usera's ticket there within 10 s of starting.

## Lock after session end (policy)

Global policy `nemo-lock-after-session-end=Y`, usera session to 91090423:

- closed from the controller: `Connection closed: Peer close` → `locking the desktop: lock-after-session-end policy`
- controller killed (`kill -9`): `Connection closed: Reset by the peer` → `locking the desktop: …`

(On the Linux lab target the lock is a Meta+L key press with nothing to lock; on Windows it
is `LockWorkStation`.)

## Client UI

- Address book cards show the full ID (`91 090 423`) and a 25-character alias; the Direkt
  pill sits on the second line. Tile view: one pill with the bolt inside, no disc.
- Second click on an open peer: "Bereits verbunden — …", one `--connect` process; a
  second peer opens next to it.
- Settings → Sprache: de → de-at (UI stays German) → en (UI English at once) → de; all
  three flags render in the row and the drop-down.

## Server-driven update rollout (client 1.4.15, server 7ac7b75)

Lab global policy: `nemo-auto-update=Y`. The Win11 VM ran a 1.4.14 build with the new
updater. `tbfdesk-1.4.15-x64-install.exe` (18 062 336 bytes, sha256 `412123a1…9b47`) was
uploaded to `POST /nemo/api/update/upload` with curl, which put `https://127.0.0.1:31120/…`
into the manifest: an address the VM cannot reach (its own loopback), so the update can
only work if the client fetches the path through its own server address.

| side | VM's management server | what the VM logged | result |
|---|---|---|---|
| A (company NAT) | `https://10.0.2.2:31120` | 15:12:45 "Nemo update 1.4.15 published (this build 1.4.14): checking now" → pending (10 min spacing) → 15:17:45 "download: https://10.0.2.2:31120/nemo/api/update/file/tbfdesk-1.4.15-x64-install.exe" → launched `--update` | 1.4.15 installed, dashboard Version 1.4.15 after 321 s |
| B (internet NAT, port-translated) | `https://192.168.2.58:41120` → forward → 31120 | cached installer deleted first; 15:20:46 "download: https://192.168.2.58:41120/nemo/api/update/file/…", fresh file, sha256 `412123a1…` | 1.4.15 installed after 45 s |

Upload guards: 10 MB without the admin token → 413 before the body is read; with the
token, a non-PE body → 400; version `../x` → 400. The file route answers HEAD with the
right Content-Length. Dashboard: Peers table Version column (12513041 = 1.4.15 in green),
Software update panel "Published: 1.4.15 — 1 of 4 machines run it or newer".

Found and fixed during the run: an HTTP/2 upload has no Host header, so the server could
not build the manifest URL ("cannot tell this server's address"); it now reads the request
URI's authority.

## Unit tests

Client: `nemo_control` (4) and `lang` (3, incl. the runtime-built German messages).
Server: 114 + 3, incl. the ticket contract and the epoch.

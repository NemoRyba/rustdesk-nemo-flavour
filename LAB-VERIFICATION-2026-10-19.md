# Lab verification 2026-10-19: client 1.4.14, server 2608fec

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

## Unit tests

Client: `nemo_control` (4) and `lang` (3, incl. the runtime-built German messages).
Server: 114 + 3, incl. the ticket contract and the epoch.

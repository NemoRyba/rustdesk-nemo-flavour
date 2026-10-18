# Lab verification 2026-10-18: client 1.4.10

Client `rustdesk-client-nemo` from `7de501470` to `fffff4a8e`, hbb_common `0f2c7e9`.
Tested in the lab2 harness (host hbbs, containerised controller on Xvnc with two
real RandR outputs, a remote with three screens) and in the Windows 11 VM, where an RDP
session with `/multimon` provides two monitors (`vm/scripts/rdp-multimon.sh`).

## Direct connections

Every failure mode of a published endpoint was reproduced with a real client and a real
peer. The resulting log lines are in
[HANDOFF-LENOVO-PC2-DIRECT.md §5](HANDOFF-LENOVO-PC2-DIRECT.md). Summary:

| endpoint leads to | before | 1.4.10 |
|---|---|---|
| nothing / a rejecting router | `Failed to connect to X` | `… connection refused` |
| a dropping firewall | `Failed to connect to X` | `… timed out after 2500 ms` |
| another service | "peer's key is unavailable" | "answered, but not with a TBFDesk handshake" |
| a host that accepts and closes | "Reset by the peer" | "accepted the connection and closed it without a TBFDesk handshake" |
| two forwards, both right | established | established in 68 ms, no relay |
| relay-only setting on | direct silently skipped | logged; **Direkt verbinden** refuses with the setting's name |
| **Direkt verbinden** refused (relay-only / no endpoint) | auto-retried, **came up over the relay** | final error, OK only |

Also found and fixed: a disabled endpoint withdraws `direct-server=Y` from the target,
which is correct but easy to mistake for a bug in a lab. A cleared endpoint turns the
target's listener off.

## Multi-monitor

| | Linux | Windows 11 |
|---|---|---|
| single / all in window | ✓ | ✓ |
| span (screens 1+2 → monitors 1+2) | ✓ | ✓ |
| window per display | ✓ | ✓ after 3 fixes (below) |
| display picker, remembered per peer | ✓ | ✓ |
| selection change inside window-per-display | ✓ | ✓ after the async-close fix |
| toolbar back from the top edge, letterboxed layout | ✓ after fix | ✓ |
| mouse through the second window | ✓ | ✓ |
| typing through the second window, keys follow the active window | ✓ | ✓ with real key presses* |

\* The guest input agent's `TYPE` uses SendKeys, which sends Unicode `VK_PACKET` events.
Text boxes accept them, but a remote-desktop keyboard hook cannot map them to keys.
Typing into a session needs the agent's new `KEYS` command (virtual key plus scan code).

### Bugs found and fixed in this round

1. **Mojibake on Windows** in every non-ASCII literal of the embedded UI. The direct-access
   tooltip and menu showed `â€"`, and the picker labels `·` and `×` were hit too. The inline
   page was decoded in the ANSI code page; a UTF-8 BOM fixes it (`e4bd9b581`).
2. **Toolbar unreachable** in span / window-per-display mode when the layout letterboxes
   (three screens on two monitors). The reveal is now wired to the background as well
   (`13535c7c7`).
3. **Black display window**: the first frame arrived before the window bound its
   surface, and a static remote screen never sends another. Every surface now requests
   a fresh frame when it binds.
4. **20-second freeze** of UI and video while opening a display window, intermittently.
   The UI thread waited for a mutex held by a thread that was waiting for the UI thread.
   That path now uses state kept on the UI thread. After the fix: 6/6 entries, windows
   in 0.19–0.28 s.
5. **Selection change in window-per-display** blanked the windows and threw the session
   out of the mode, because Windows closes windows asynchronously and the late close
   cleaned up its replacement. Display windows now carry an id (3–5 in `fffff4a8e`).

## Known limits

- With more remote screens than local monitors, window-per-display stacks the extra
  windows on the last monitor. Use the picker to choose which screens to show.
- Windows reserves the real Ctrl+Alt+Del. On a Windows controller, use Ctrl+Alt+End,
  which sends Ctrl+Alt+Del to a Windows remote. Not testable end to end here: the lab has
  no Windows remote.
- QEMU's `secondary-vga` has no Windows driver. A Windows guest gets two monitors only
  through RDP `/multimon`.

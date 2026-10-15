# Handoff — Windows workstation, direct connection over two port forwards

**For:** a Claude Code instance running on the Windows remote.
**Goal:** make one Windows workstation reachable **directly** (no relay) from a controller
on the internet, through port forwards on both routers, and **measure whether it recovers
the ~36% the relay costs**. That number is the whole point of the exercise.

**Explicitly out of scope: the port knock.** The SPA/knock layer is built and verified but
stays **off** for this round. Leave every `nemo-knock-*` setting unset. The direct path works
without it; the knock is a separate hardening layer added later
(see [DIRECT-CONNECTIONS.md](DIRECT-CONNECTIONS.md) and OPEN-TODOS 11c).

---

## 0. Blockers you do not own — check these first

Do not start until both are true, or you will debug the wrong thing.

### 0a. The commits must be pushed

As of 2026-10-15 the direct-endpoint work is committed but **NOT pushed**:

| repo | ahead of origin |
|---|---|
| `rustdesk-nemo-flavour` (superproject) | 3 |
| `rustdesk-client-nemo` | 3 |
| `rustdesk-server-nemo` | 1 |

You cannot build what you cannot clone. Confirm `git log --oneline -1` on `nemo-tdd` shows
at least `0ced5ee8c` in the client submodule before building.

### 0b. The server — DONE 2026-10-15

`hbbs` with the direct-endpoint feature is **deployed and live** on the VM:

```
/usr/bin/hbbs                Okt 15 21:26   build_id "18a2f00 2026-10-07"
rustdesk-hbbs-nemo.service   active (running)
previous binary kept at      /usr/bin/hbbs.bak-2026-10-15   (rollback)
```

Verified live: both registered peers now carry the `direct_endpoint` field, and
`POST /nemo/api/peers/:id/direct-endpoint` refuses a malformed value with a 400 and the
reason. `hbbr` was unchanged (no relay-side changes in this work).

So the only remaining blocker is 0a.

---

## 1. Build the Windows client

The recipe exists; do not re-derive it.

- Script: `build-run-windows-client.ps1` (repo root).
- Packaging into one installer: `scripts\package-windows-client.ps1` → `dist\tbfdesk-<ver>-x64-install.exe`.
- Features: `--features inline,hwcodec,vram`. Without `inline` the UI loads from `file://$CWD`
  and you get a white window.

**Gotchas that have each cost a full build — all previously hit, all real:**

1. Run everything inside `vcvars64.bat`, including vcpkg, or `rc.exe`/`mt.exe` are not found.
2. VS Build Tools does **not** install the Windows SDK via `--add ...Windows11SDK.22000`
   (silently skipped). Use standalone `winsdksetup.exe` with `/features +`. Without it every
   vcpkg native port dies at cmake config (`CMAKE_MT-NOTFOUND`).
3. `VCPKG_ROOT` + `LIBCLANG_PATH` (LLVM 15.0.6) must both be set. `.cargo/config.toml`
   already forces `+crt-static`, so vcpkg picks `x64-windows-static` by itself.
4. If guest Python is missing, generate `src/ui/inline.rs` on the Linux host with
   `inline-sciter.py` and copy it in — it is pure/portable. `mod inline;` needs that file or
   you get `E0583`.
5. hwcodec needs vcpkg port **`mfx-dispatch`** (not the removed `intel-media-sdk`); the extra
   link libs are already handled in `rustdesk-client-nemo/build.rs` `build_windows()`.

Build from a **real git checkout**, not an scp'd tarball, or the build id stamps as
"Build unknown".

---

## 1b. The server key — get this right or nothing registers

Every client needs the server's Ed25519 public key, as **both** `key` and
`nemo-management-public-key` (or baked into the licence name as `key=…`). With the wrong
one the client never registers and never accepts policy.

**As of 2026-10-15 the live key is:**

```
zn4AbcDYxxlvp+czrKHEWOY3JBvYw5dKLbwRslK4nlo=
```

**Do not take it from a file in a repo checkout.** `hbbs` silently generates a keypair in
its working directory whenever it finds none, so every lab or dev run leaves behind an
`id_ed25519.pub` that looks authoritative and is not. On 2026-10-15 there were **four**
distinct keys in circulation — the live one above, one in this box's Sep-4 client config
(`XsN4…`, pre-dating a Sep-28 rotation), and one stray `id_ed25519.pub` in each of two repo
checkouts (`853J…`, `KZTG…`). A build was nearly configured against one of the strays.

Authoritative sources, in order:

1. Dashboard → **Settings** → *Server identity key* (read-only, click to copy).
2. `GET /nemo/api/health` → `server_public_key`.
3. On the server: `/var/lib/rustdesk-server/id_ed25519.pub`.

If the dashboard shows a **"Restart pending"** warning there, the key was rotated and hbbs
has not been restarted — the running key and the file disagree. Ask the operator which one
to provision against before building anything.

## 2. Roles

Simplest topology, and the one to use:

| role | machine | why |
|---|---|---|
| **controlled** (gets connected to) | the Windows workstation | this is what we want reachable directly |
| **controller** (connects out) | the Linux dev box | already running the new client, so it is not a variable |

The **controller must be the new build** — the direct-endpoint logic lives there. The
controlled side mainly needs its direct-access listener, but build it from the same commit
anyway so you are not comparing two different binaries.

---

## 3. Configure the Windows side

Config file: `%APPDATA%\RustDesk\config\RustDesk2.toml` (under `[options]`).

```toml
direct-server       = 'Y'
direct-access-port  = '21118'
disable-udp         = 'Y'
```

Notes, each of which has bitten someone already:

- **`disable-udp = 'Y'` is mandatory.** The server runs `--udp-registration=N`, so plaintext
  UDP registration is refused and the client never comes online — it just loops
  `register_pk ... due to key not confirmed` forever. The server log says so explicitly.
- **`direct-server` is pushed automatically** by the new server once you set an endpoint for
  this peer, so you may not need to set it by hand. Setting it anyway is harmless.
- **`direct-access-port` is the port the workstation LISTENS on.** It is *not* the port you
  type into the dashboard. A forward may translate (`external 31118 → internal 21118`).
- Restart the client after editing, and confirm:
  `Direct server listening on: Some(Ok([::]:21118))` in the log.

---

## 4. The port forward — already done for you

The operator has forwarded **external TCP 21666 → this test workstation** (2026-10-15). So:

```
internet ──→ 85.126.226.2:21666 ──→ <this workstation>:21118
                (router)              (direct-access-port)
```

You do not need to touch the router. What you DO need is for the workstation to actually be
listening on 21118 — see §3.

**Expect `21666` to read as closed/filtered until your client is running.** A forward to a
host with nothing listening behind it looks exactly like no forward at all. Probing it before
the client is up proves nothing; probe it after. From the internet side:

```powershell
Test-NetConnection -ComputerName 85.126.226.2 -Port 21666
```

If it is still refused once `Direct server listening on: Some(Ok([::]:21118))` is in your log,
then the problem is the forward or the Windows firewall (see §9).

---

## 5. Set the endpoint in the dashboard

Dashboard → **Peers** → select the Windows workstation → **Direct connection** → *Reachable at*:

```
85.126.226.2:21666
```

That is the **router's external** address and the port forwarded to this workstation. Save.
The value is validated server-side, so a typo comes back as an HTTP 400 with the reason
rather than silently doing nothing.

Do **not** put `21118` here — that is what the workstation listens on internally, and the
router translates `21666 → 21118`.

Clients pick it up on their next policy poll (≤30 s).

**Two reasons the endpoint will be withheld even when set** — both are correct behaviour, and
both have already caused confusion:

- the peer is **blocked** (a blocked peer's address is never handed out), and
- the controller's `nemo-outbound-targets` does not permit that target.

If the controller's policy never shows `nemo-direct-endpoints`, check those two first.

**Admin page access.** The operator reaches the dashboard over the internet from an
allowlisted source; port 21120 is source-restricted on the router, so it will likely be
**closed from wherever you are**. You probably do not need it — the operator sets the
endpoint (this section) — but if you do:

- From the LAN: `https://192.168.1.14:21120/nemo/admin`.
- From anywhere with SSH to the VM:
  `ssh -L 21120:127.0.0.1:21120 -p 1234 dev@85.126.226.2`, then
  `https://127.0.0.1:21120/nemo/admin`.
- The bearer token is `NEMO_API_TOKEN` in `/etc/tbfdesk/hbbs.env` on the VM (root-readable;
  ask the operator rather than guessing). It is deliberately not written into this file.

Note the allowlist is pinned to a Starlink address, which rotates — it moved from
`150.228.29.99` to `150.228.29.172` between 2026-10-07 and 2026-10-15. If the dashboard is
suddenly unreachable for the operator, that is the first thing to check, not a server fault.

---

## 6. Verify

**Controller log** — this is the verdict. Find it under `%APPDATA%\RustDesk` on Windows, or
`~/.local/share/logs/RustDesk/` on Linux (the `--connect` run writes its own file under
`connect/`):

Success:
```
TBFDesk direct: trying <ip>:<port> for <id> (budget 2500ms)
TBFDesk direct: established with <ip>:<port> in 4.1ms, no relay
```

Fallback (feature working correctly, forward not):
```
TBFDesk direct: 203.0.113.5:31118 unusable (Failed to connect to ...); falling back to hole punch / relay
TBFDesk direct: 203.0.113.5:31118 did not complete within 2500ms; falling back to hole punch / relay
```

No `TBFDesk direct:` line at all ⇒ the controller never got an endpoint for that id. Go back
to §5 and §0b.

**Controlled log:** `direct access from <ip>:<port>`.

**In the session UI:** the connection-type badge reads **TCP**, not **Relay**, and the peer's
*Forced Relay* counter in the dashboard stops advancing.

---

## 7. The measurement — the actual deliverable

Baseline to beat, from `LAB-VERIFICATION-2026-10-06.md`: the WAN link carries **11.1 Mbit/s**,
and a 20 MB file transfer **through the relay** managed **7.1 Mbit/s = 64%**. `hbbr` was
capped at 10 Gbit/s, so the loss is the extra hop.

Repeat exactly that measurement on the direct path: same file size, same direction, same time
of day if you can. Report Mbit/s and the percentage of link. Also note the session's RTT —
the lab WAN path was 64 ms.

A direct path that does **not** beat 7.1 Mbit/s is a finding, not a failure to report quietly:
say so with the numbers.

---

## 8. Known environment constraints

Neither is caused by this feature; both will waste your time if you hit them blind.

- **The client IPC socket path is UID-based** (`/tmp/RustDesk-<uid>/ipc` on Linux), not
  HOME/XDG-derived. Two full clients cannot coexist as one user on one host — the second dies
  with `Address already in use`. Use separate machines.
- **The peer id is machine-derived.** Two clients on one host generate the *same* id, and the
  second overwrites the first's pinned key on the server. Distinct peers need distinct hosts.

---

## 9. If it still goes through the relay — in order of likelihood

1. **Windows Defender Firewall is blocking inbound 21118.** This is the single most likely
   cause and it is silent: the listener is up, the forward is right, and the TCP SYN is
   dropped at the host. Nothing in the TBFDesk log says so. Add the rule:

   ```powershell
   New-NetFirewallRule -DisplayName "TBFDesk direct access" -Direction Inbound `
     -Protocol TCP -LocalPort 21118 -Action Allow -Profile Any
   ```

   Then re-probe `85.126.226.2:21666` from outside.

2. **The client is not registered.** Check for `register_pk ... due to key not confirmed`
   looping in the log — that means `disable-udp = 'Y'` is missing (§3). The peer shows
   offline in the dashboard and gets no policy at all.

3. **No endpoint in the policy.** Grep the client config for `nemo-direct-endpoints`. If
   absent: the endpoint is not set (§5), the peer is blocked, or the controller's
   `nemo-outbound-targets` excludes this target.

4. **The controller is the old binary.** The direct-endpoint logic lives on the *connecting*
   side. An older controller ignores the endpoint entirely and goes straight to the punch —
   with no `TBFDesk direct:` line at all, which looks identical to case 3.

5. **The endpoint has the internal port in it.** `85.126.226.2:21118` instead of `:21666`
   will connect to nothing (or to the wrong thing). The dashboard field takes the
   **router's external** port.

Each of these produces a *working* session over the relay, so "it works but it is slow" is
the symptom for all five. Use the log lines in §6 to tell them apart, not the session itself.

## 10. Report back

1. Did the direct path establish? Paste the `TBFDesk direct:` lines verbatim.
2. Throughput on the direct path vs the 7.1 Mbit/s relay baseline, as Mbit/s and % of link.
3. Anything that needed a step not written above — this document is wrong if you had to
   improvise, so say what was missing.

Reference: [DIRECT-CONNECTIONS.md](DIRECT-CONNECTIONS.md) has the full design, every config
key, the per-controller filtering rules, and the end-to-end simulation this is the live
follow-up to.

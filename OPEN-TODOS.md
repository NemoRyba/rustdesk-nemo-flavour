# TBFDesk — Open TODOs (ranked, **each item verified against code/live state on 2026-09-02**)

**Goal:** a performance-oriented, centrally-managed, **direct** remote-control product.
**Priority order:** Security edge ▸ Management capability ▸ Performance observability ▸ Polish.
**Companion docs:** [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) (transport security detail), [HANDOFF.md](HANDOFF.md) (session state + recipes), `TODO.md` (running log), `.claude/plans/analyze-this-repository-and-fizzy-parrot.md` (full roadmap).

---

## SECURITY

> **2026-09-27:** This file is history. The live open-items register is `../OPEN-POINTS-2026-09-21.md` (see README *Known gaps*). On 2026-09-25 three items landed: H11/H20/H22 ACL version check and H23/M13 session eviction (server `0231ccd`, completed by `897a00b` — as first committed the admin UI emptied its allowlist after a save), and H24 main-IPC authorization (client `9e18fa9e1`, reverted in `feaf523f9`: the socket was already 0600 in a 0700 dir, and the check broke root CLI commands). S-B sealing, M1, S-C, A4 and the L-items are the **2026-09-03** work below, not new.
>
> **2026-09-03:** S-B core + H4 + M1 + S-C + all L-items are **CODE-COMPLETE (uncommitted, not yet deployed to 176, not yet screenshot/live-verified).** Server suite green (48 tests); client compiles clean. Detail in [SECURITY-HARDENING-TODO.md](SECURITY-HARDENING-TODO.md) (2026-09-03 session). What remains open below is the transport/proto tier (M2, S-D, S-E, cert-pin enforcement), all blocked on the hbb_common fork remote (#9) and/or lockstep rollout.

### 1. S-B + H4 — trust for the management control plane  *(CORE DONE; cert-pin enforcement remains)*
*Was:* clients run with `allow-insecure-tls-fallback = 'Y'` against the self-signed cert, and the policy response delivered secrets unsealed, authed only by id+uuid.
**DONE (uncommitted):** the policy-poll response AND `/api/ab/get` are now **sealed to the provisioned device key** (sign-then-seal, NaCl sealedbox, Ed25519→Curve25519) when the client proves a pinned key — a MITM under a forged cert sees ciphertext. Client has an anti-downgrade ratchet. H4 gets an opt-in **`strip_unsealed_secrets`** mode that strips secrets from any response that can't be sealed.
**REMAINING (S-B item 5):** CA-signed/fingerprint-pinned cert with the insecure fallback OFF. The `nemo-api-cert-fingerprint` policy key is plumbed + persisted on both ends, but the rustls `PinnedVerifier` + retry-ladder short-circuit is **not built yet** (needs `libs/hbb_common/src/verifier.rs`).

### 2. M1 — device keys are a shared pool  *(DONE, uncommitted)*
Keys can now be **bound to a peer id** (`DeviceKey.peer_id`); `verify_device_signature` refuses a signature whose claimed id ≠ binding. Dashboard has a "bind to TBFDesk ID" field. Legacy unbound keys still work until re-provisioned.

### 3. M2 — blocklist trusts a self-reported id  *(OPEN — needs a proto change)*
*Verified:* the controlled side rejects blocked peers on `lr.my_id`, a field the CONNECTING client fills in. Fix = add a controller-signed `signed_id` to the `PublicKey` handshake message (proto change) and verify it against `nemo-peer-keys`. Blocked on hbb_common fork remote (#9) + lockstep rollout.

### 4. Smaller hardening (per the 2026-09-01 audit)
- **S-C** *(DONE, uncommitted)*: LDAP `tls_verify=false` now **fails closed** unless `--insecure-ldap-i-accept-mitm Y` is passed.
- **S-D** *(OPEN)*: cross-direction nonce reuse on the shared secretbox key (primitive-level, lowest severity). Needs a `tcp.rs` + proto-negotiation change (hbb_common) to avoid breaking mixed-version sessions.
- **S-E** *(OPEN)*: port-forward/RDP tunnels drop the E2E layer. Remove the two `set_raw()` calls, version-gated (hbb_common). Low practical risk here (direct desktop; tunnels likely unused).
- **L-items** *(DONE, uncommitted)*: admin API fails closed without a token (auto-generates+logs one); sealed-login nonce replay guard (ts==0 bypass removed); login user-enumeration collapsed; device-key id collision fixed; `nemo-management-allow-unsigned` compiled out of release builds.
- **S-A residue** (S-A itself ✅ closed 2026-09-02): optional TOFU store for peers absent from the pushed key map — such peers currently fail closed, which is acceptable.

---

## MANAGEMENT capability — verified open

### 5. Server-driven client updates / TBF update server  *(does not exist)*
*Verified:* the upstream updater posts to the public RustDesk version URL, which this fork blocks; no update/version/download route exists on the nemo-api. The client's "Automatisch aktualisieren" row is DORMANT (greyed, non-editable, interval clamped 1–30 days) until this exists.
**Design:** admin sets target version + download URL in the dashboard → delivered via the signed policy poll → client compares `get_version()`, downloads from the api-server (:21120), verifies an Ed25519 signature over the binary (reuse the policy-signing path) → installs (silent install needs the installed-service path).

### 6. Real force-disconnect  *(cut only blocks NEW connections)*
*Verified:* `/nemo/api/connections/cut` routes to a block-only handler; a live DIRECT session has no server data path. Needs a client-honored kill signal (designed, not built) — deliverable via the signed policy poll.

---

## PERFORMANCE / observability — verified open

### 7. Relay-vs-direct **byte** metrics  *(DONE 2026-10-16, not seen live — server `nemo-tdd`)*
*Was:* `relay_server.rs` exported no per-session byte counters, so the dashboard could only show relay NEGOTIATIONS — which say a path was offered, not that a byte went through it.
**Done:** hbbr gained `usage-json`/`uj` (the machine-readable twin of `usage`, which is unchanged); hbbs remembers `label -> (controller id, workstation id)` when it mints a relay grant and polls hbbr over its existing **loopback** admin channel, so no new authentication is involved and the live grant never leaves hbbs — the join key is `common::relay_session_label`, a hash of it. Cumulative samples are folded into deltas (fleet total counted once, both peers charged individually). Dashboard: a **Relayed bytes** panel (bytes, rate, peak, duration, live/ended/**unused — went direct**), the fleet total in the Connections header, and a per-peer row in the detail panel. Flags: `--nemo-relay-metrics <host:port>` (default `127.0.0.1:21117`, `""` or `N` disables), `--nemo-relay-metrics-interval` (default 5s).
**Open:** needs an hbbr answering `uj` on the same host to show anything — not verified against a real relayed session yet. hbbr binds its admin channel to loopback, so a relay on another host needs a tunnel (or the feature off).

### 8. `NemoSource` protobuf field  *(DONE 2026-10-16, not seen live)*
*Was:* controller identity rode smuggled in the rendezvous `version` string (`nemo-source-v1:<id>:<uuid>[:token]`) and, on the relay path, in `licence_key`.
**Done:** `NemoSource {id, uuid, token}` on `PunchHoleRequest` (field 11) and `RequestRelay` (field 10) — hbb_common `nemo-tdd` `7ad1c09` / `nemo` `a8396b5`, the same commit on both branches. New field numbers only, so an un-updated peer on either end keeps working. The server's `controller_source_any()` prefers the typed field, falls back to the marker, and logs a client that sends both and disagrees with itself; the field is threaded through all four controller gates and both recorders, and is wiped from the relay frame before it is forwarded (it carries the technician's session token, like `licence_key`). The client sends both for now.
**Still asserted, not proved** — and deliberately so: what proves a controller is the device-key handshake, which `resolve_controller_identity` keeps preferring. The field removes the ambiguity, not the need for the proof.
**Open:** a lockstep rollout is still what makes the marker removable; nothing can be deleted until every client in the field sends the field.

### 9. hbb_common fork remote  ✅ RESOLVED 2026-09-03
Forked to **github.com/NemoRyba/hbb_common** (public) + a **176 bare mirror** (`~/git/hbb_common.git`). The `nemo` branch (`40adca6` + A4 `b6aa3ca`) is pushed to both; the client `.gitmodules` now points at NemoRyba (branch `nemo`) and the gitlink is committed (`ef99cce88`, pushed to NemoRyba + 176). Fresh recursive clones now resolve. hbb_common remotes: `origin`=NemoRyba, `ubuntu`=176, `upstream`=rustdesk/hbb_common.

### 10. Rebuild the 176 Linux host binary  *(checkout is current, binary is not)*
*Verified:* client checkout on 176 reconciled to `nemo-tdd` HEAD on 2026-09-02, but `/opt/nemo-rustdesk/rustdesk` is dated 2026-08-31. Rebuild (Rust 1.75, `inline,linux-pkg-config`) and atomic-replace + `systemctl restart rustdesk-nemo.service`.

---

## NEEDS THE USER / infrastructure (not verifiable from the dev box)

### 11. Topology move 2026-09-04 — server VM is now `192.168.1.14` (DMZ), public `85.126.226.2`  *(IN PROGRESS)*
Design + router commands: [TOPOLOGY-DEPLOYMENT.md](TOPOLOGY-DEPLOYMENT.md). Checklist:
- [ ] Router A: static route `192.168.0.0/24 via 192.168.1.2`, DHCP reservations for `.2/.13/.14`. Router B: static WAN, wan-zone `masq=0`, ACCEPT rule `192.168.1.14 → 192.168.0.151 tcp/636` (LDAPS — without it every login fails).
- [ ] VM: `sudo -E bash scripts/vm-apply-server-address.sh` (hbbs `-r 85.126.226.2:21117 --local-ip 192.168.1.14`, dev+gdm client configs → `192.168.1.14`, restart, reachability check).
- [x] pc2 `RustDesk2.toml` → `192.168.1.14` (done 2026-09-04; backup kept). Then log in on the client and screenshot-verify the new *Sync clipboard between sessions* row.
- [ ] Dashboard → Global client defaults: keep `api-server` EMPTY until a DNS name exists (one value can't serve LAN + internet clients).
- [ ] Router A port forwards → `192.168.1.14`: TCP 21115/21116/21117 + UDP 21116 now; **21120 only after** the cert pin (#1) is enforced and `allow-insecure-tls-fallback` is off fleet-wide, or reach it via WireGuard. Never forward to a workstation.
- [ ] DNS name (split horizon: `192.168.1.14` inside via the DC, `85.126.226.2` outside) → then use it in `-r`, all client configs, the locked-exe names, and the cert.
- [ ] Optional server feature before 21120 goes public: source allowlist for `/nemo/*` (admin API + dashboard) so only LAN/VPN reaches it while `/api/*` stays open to clients.
- Whereabouts of the second VM (was `192.168.0.179`) after the move: unknown — decide whether it comes back as `192.168.1.x`.

### 11b. WAN/NAT path measurement + per-workstation codec tuning
Needs the real topology (now in place, see 11) and a person at both ends (e2e/ harness is ready). Related: both OpenWrt 19.07.1 routers are EOL — upgrade (S10) before exposing the DMZ to the internet.

### 11c. Router: upgrade firmware, then run `fwknopd` at the edge  *(DEFERRED 2026-10-06 — needs a firmware flash)*
*Verified 2026-10-06:* installing `fwknopd 2.6.10-3` on the **external** router (LuCI → Software) fails with
`Required dependency package kernel is not available in any repository`. The package pulls
`iptables` → `kmod-ipt-core` → `kernel`, and every OpenWrt `kmod-*` is pinned to the exact kernel of
the build the router is running. Nothing in the repo matches, so **no kernel module can be installed
on that router at all** — not just this one. Expected on an EOL 19.07.1 whose kmod feed is gone or
re-spun. (The dialog also showed `iptables` itself as NOT INSTALLED, which would be unusual on
19.07/fw3 — so confirm the actual release before choosing a path.)

Diagnose first: `cat /etc/openwrt_release; uname -r; opkg print-architecture; which iptables nft fw3 fw4`.

Paths, in order of preference:
1. **Upgrade both routers to a supported OpenWrt release**, then install `fwknopd` from a live feed.
   This is the real fix and S10 already requires it before the DMZ faces the internet. An EOL router
   is a poor place to *add* a security control.
2. If the router turns out to be 22.03+ with **fw4/nftables**: try `iptables-nft` instead of legacy
   `iptables`. It provides the iptables CLI over nftables with **no legacy kmods**, which may satisfy
   `fwknopd`'s dependency without touching the kernel at all.
3. **ImageBuilder** a firmware with `fwknopd` and deps baked in. Reliable and reproducible for both
   routers — but it is a flash either way, so (1) is better.
4. **Move the gate off the router:** run `fwknopd` on the server VM (default-DROP, opened per source
   by a valid SPA) with the router forwarding blindly. Protects the *server* ports (21120 admin,
   21116/21117) and needs no router packages. Does **not** cover per-workstation direct ports — the
   gate must live where the traffic lands, and fwknop on Windows is Cygwin-based and not deployable.

**Until a router can gate:** per-workstation direct forwards are protected by **source-IP allowlists**
on the router (no packages, works on 19.07 as-is) — adequate while technician IPs are static, and the
only option left if they roam. Do (4) for 21120 regardless, since it is the admin surface.

**None of this blocks the client work:** the knock is implemented and the SPA packets are byte-for-byte
fwknop-compatible (`rustdesk-client-nemo/src/nemo_direct.rs`, contract test
`spa_encoder_reproduces_the_real_fwknop_packet`), so it does not care whether `fwknopd` ends up on the
router, the server VM, or a replacement edge box. Only `nemo-knock-port` changes.

---

## PROVISIONING UX + Windows branding — reported 2026-10-16 from the Windows test workstation
*(16 is a rollout blocker and is placed here by priority; the numbers continue at 16 so existing references to 12–15 stay valid. Code refs below re-checked against the tree on 2026-10-16.)*

### 20. Client setup string  *(DONE 2026-10-16, not seen live)*
A fresh client needed **six** exact server values typed in before it could reach the server at all — ID/rendezvous server, relay, api-server URL, management URL, the server's identity key, its certificate fingerprint — plus the device key. One wrong character fails as "cannot reach the server".
**Done:** the dashboard hands them over as `tbfdesk-setup-v1:<base64 json>`, **twice** — an `internal` (LAN) and an `external` (public) profile, since the server has two addresses and a client carries one set; the public one is derived from `-r` and never from the dashboard address, and says so rather than guessing when the server has none. *Settings → Device keys* has the editable fields (prefilled from the dashboard's own Host header) with **Copy string** / **Download file**; generating a device key returns the same bundle **with that key inside it**. The client's *Import device key* dialog takes either a bare key or a setup string, plus **Load from file…**; `tbfdesk --import-setup <file|string>` does it unattended. Server `/nemo/api/client-setup` (GET defaults, POST edits), overrides `--nemo-client-id-server` / `--nemo-client-relay` / `--nemo-client-api`.
**Open:** not exercised against a real client yet (no Windows/Sciter build here). The bundle is the client's trust anchor and is deliberately unsigned — what a signature would be checked against is the key inside it — so it must be handed over like a password.
**Side effect worth knowing:** *Load from file…* is also a working paste-free route into that dialog, which is most of what **16** below is about.

### 16. "Geräteschlüssel importieren" dialog: **Ctrl+V does nothing**  *(blocks provisioning — partly worked around by 20)*
**2026-10-16:** the setup-string work (20) added a **Load from file…** button to this dialog, which is candidate fix #1 from the list below and sidesteps the clipboard entirely: the operator downloads the `.tbfsetup` from the dashboard and picks it. Ctrl+V itself is still unfixed, and the diagnostic below is still the way to find out which layer eats it.
Reported on the installed Windows client. This dialog is the **only** way a device key reaches a client (`rustdesk-client-nemo/src/ui/index.tis:601` `open_import_device_key_dialog`), the key is a 44-char base64 secret nobody will retype correctly, and Layer 1 makes it mandatory — so broken paste is a rollout blocker, not a cosmetic bug.

**Already ruled out** (static read, no VM needed): no TIS handler eats the keystroke. The two in scope — `msgbox.tis:303` and `index.tis:2365` — both guard on `if (!evt.shortcutKey)`, so they skip every Ctrl-combination, and neither returns `true`; the third (`common.tis:219`) is scoped to the chatbox behavior and never sees this dialog.

**Constraint on any fix:** the field is `<input|password name='devkey'>` (`index.tis:608`) and the masking is deliberate — `index.tis:602-604` records why: with the key rendered, a remote operator watching the screen could copy this machine's Layer 1 identity straight out of the input. A fix must keep that property.

**First diagnostic (≈2 min on the workstation, no rebuild)** — try Ctrl+V in each of:
1. the **permanent-password** dialog — also `input|password` (`index.tis:1279`),
2. the **IP-whitelist** dialog — a plain `<textarea>` (`index.tis:645`),
3. the **ID field** on the main window.

All three fail → host/Sciter clipboard integration. Only the two password fields fail → Sciter's masked edit refuses paste. Only this dialog fails → something specific to it. Also try **Shift+Insert** and right-click in the field; whichever works is the interim line to add to the provisioning instructions.

**Candidate fixes, best first:**
- **An "Einfügen" button beside the field** that reads the clipboard on the Rust side and sets the value. Sidesteps Sciter's edit behavior entirely, keeps the masking, and works whichever layer turns out to be at fault. Needs no new dependency: `arboard` is already in `Cargo.toml:109` and the UI↔Rust bridge exists (`src/ui/inline.rs`).
- A **"Schlüssel anzeigen"** toggle that switches the field to `input|text` while held — cheap, but erodes the on-screen-secret property above; worth it only *alongside* the button, not instead of it.
- Chasing it inside Sciter's own `behavior:edit` — last resort, we do not control that code.

**Acceptance:** a key can be entered by Ctrl+V *and* by the button; a bad paste still keeps the dialog open with the existing error (`index.tis:618-624`); the key is still never rendered in plaintext.

### 16b. "creating Geräteschlüssel at …" — **report truncated, needs one detail**
The 2026-10-16 message breaks off mid-sentence, so the ask is unknown. For the record, the flow it points at: keys are minted in the dashboard's **Device keys** panel (`rustdesk-server-nemo/src/nemo_admin.html:931`, button `#generateDeviceKey` → `POST /nemo/api/device-keys`), the private half is **shown once** and must be copied immediately, then pasted into the client via 16's dialog. Open question for the user: is this (a) a second bug on that panel, (b) the same copy/paste problem at the *server* end, or (c) a request to document where keys are created?

### 19. Device-key first-use binding with operator confirmation  *(IMPLEMENTED, not deployed — see [DEVICE-KEY-CLAIM.md](DEVICE-KEY-CLAIM.md))*
Provisioning deadlocks: the key wants the TBFDesk id, the client shows no id until it is past the provisioning gate, and it cannot pass the gate without a key. Design (2026-10-16): an unbound key is a one-shot provisioning token; the first client that proves it **files a pending claim** the operator confirms or denies in the peers panel; only that confirmation writes the binding. A pending claim grants nothing, so it doubles as the "unverified client" view.
**Done 2026-10-16** (server `nemo-tdd`, client `nemo-tdd`): pending-claim store with per-key and global caps, both enforcement points converted to *prove → file a request → refuse*, approve/deny/forget/bind-by-hand routes, the confirm/deny UI in the peers panel **and** a pending section in the Device keys panel (the rendezvous handshake precedes `register_pk`, so a claim can name an unregistered id), a distinguishable 403 and a *"Waiting for approval by your administrator"* gate card in the Sciter client, and 96/96 tests — including the TASK #14 canary, green again **without** editing its assertion. `persist()` is now a no-op under `#[cfg(test)]`, which closes the hazard of a test writing `nemo_integration.json` into the checkout. **Open:** not deployed (the lab VM still runs `0747b0b`), no Flutter gate card, and the address-book/login endpoints still answer the generic 403. Full detail in `DEVICE-KEY-CLAIM.md`.

### 17. Windows: the installed client is **not findable as "TBFDesk"**  *(DONE 2026-10-16, UNVERIFIED on Windows — client `nemo-tdd`)*
**Done:** `DISPLAY_NAME`/`get_display_name()` in `common.rs`; the shortcut file names, the Start-menu folder and the uninstall `DisplayName`/`Publisher` use it; `build.rs` sets `ProductName`/`FileDescription`/`OriginalFilename`/`CompanyName`; the installer deletes the old `.lnk` names and the old Start-menu folder, and the uninstaller clears both names, so an upgrade does not leave two entries. `APP_NAME`, the config dir, the service, the registry key name, the exe file name and the URI scheme are untouched.
**The acceptance checks still have to be run on the test workstation** — this cannot be compiled or installed from the Linux dev box: search "TBF" in the Start menu, Apps &amp; Features, Explorer's Description column, and prove the ID and saved password survive the upgrade.

Original report:
Every OS-level label derives from `APP_NAME`, still `"RustDesk"` by design (`libs/hbb_common/src/config.rs:111`, via `common.rs:1064`; see 14 and `RENAMING-PLAN.md`). Windows Start-menu search indexes the **shortcut file name** and the exe's **version-info**, and both read RustDesk today:
- shortcuts are built as `{app_name}.lnk` / `Uninstall {app_name}.lnk` / `{app_name} Tray.lnk` (`src/platform/windows.rs:1572/1591/1622-1623`), where `app_name = get_app_name()`;
- `ProductName` / `FileDescription` / `OriginalFilename` fall back to winres defaults, i.e. to `Cargo.toml:2` `name = "rustdesk"` and `:7` `description = "RustDesk Remote Desktop"`, because `build.rs:41-47` sets only the icon and the manifest;
- plus hard-coded `…\RustDesk\…` staging paths at `windows.rs:1975-1976`.

**The point: this does not need the `APP_NAME` migration.** `RENAMING-PLAN.md` defers the rename because `APP_NAME` anchors the config dir, the service name and the registry — but none of those are what Windows *searches*. Separate the **display** name from the **identity** name:
- add `get_display_name()` → `"TBFDesk"` (new constant, `APP_NAME` untouched), used only for shortcut labels, the uninstall `DisplayName` **value** (the key *name* stays), the window title and the tray tooltip;
- in `build.rs`, set `ProductName` / `FileDescription` / `OriginalFilename` explicitly — three lines, and no crate rename (the plan recommends keeping `name = "rustdesk"`);
- **upgrade detail:** renaming the `.lnk` leaves the old `RustDesk.lnk` in place, so the installer must delete the old shortcut names or an upgraded machine shows *both* entries.

This is the cheap, non-breaking slice of what `RENAMING-PLAN.md` defers — recorded there as **Layer 0**.
**Acceptance:** typing "TBF" in the Start menu finds the client; Apps & Features shows TBFDesk; Explorer's Description column on the exe reads TBFDesk; config dir, service and registry are provably unchanged (no re-registration, ID and saved password survive).

### 18. Finish removing "RustDesk" from the program, the deployment and the operator steps  *(bucket 1 DONE 2026-10-16; buckets 2–3 open by design)*
**Done (bucket 1, user-visible labels):** 892 translated values across 49 locales; the three keys whose EMPTY value made English and German fall back to the key text (`About RustDesk`, `Keep RustDesk background service`, `Show RustDesk`); `res/` display fields (`.desktop` `Name`/`Keywords`, the service `Description`, `PKGBUILD` `pkgdesc`, the rpm specs' `Summary`/`%description`); one hard-coded Flutter window label. Kept on purpose: the AGPL attribution and the two `rustdesk.com/docs` links. Left alone with the reason recorded: `res/msi` (its `--app-name` substitution also renames the service and paths, so that is a bucket-2 change in disguise), `res/DEBIAN/*`, and **our own docs** — audited line by line, what remains is `%APPDATA%\RustDesk`, `RustDesk2.toml`, `RustDesk.exe`, `/tmp/RustDesk-<uid>`, the `FOCUS RustDesk` window class, host paths and upstream discussion, i.e. exactly the things #18 warns not to rename before Layer 2 ships. Per-file verdicts: `RENAMING-PLAN.md`.
**Open:** buckets 2 and 3, which are `RENAMING-PLAN.md` Layers 1–5 plus the config migration.

Original report:
`RENAMING-PLAN.md` already specifies the app-side job (Layers 1–5 plus the migration, recommended *after* server-driven updates #5 exist). What the 2026-10-16 report adds is that the ask covers **deployment and the written steps**, not just the binary.

Measured state 2026-10-16 (lines matching `RustDesk|rustdesk`): `src/lang/de.rs` **1** — the German UI is effectively done; `src/lang` overall **952** (the other locales); `res/` **242** (`.desktop`, `PKGBUILD`, `DEBIAN`, `msi`, rpm/flatpak specs); `src/platform` **94**; `flutter/lib` **93**; `Cargo.toml` **28**; `src/ui` **16**. Our own docs/scripts still carrying the name: `DEPLOY.md`, `DEPLOYMENT-STEP-BY-STEP.md`, `HANDOFF.md`, `HANDOFF-WINDOWS-DIRECT.md`, `README.md`, `RUNBOOK-LOCAL-MODEL.md`, `LAB-VERIFICATION-2026-10-06.md`, `UPSTREAM-SYNC.md`, `e2e/*.ps1`, `scripts/vm-apply-server-address.sh`, `build-client-fast.cmd`.

**This is not a find-replace.** Triage the inventory into three buckets before touching anything:
1. **User-visible labels** → rename (the remaining locales, packaging display names, installer text, docs addressed to operators/users).
2. **Identity, paths, service and binary names** → only via `RENAMING-PLAN.md`'s migration; renaming these in docs *before* the code moves makes the runbooks wrong (the lab server's unit, binaries and paths genuinely are `rustdesk*` today).
3. **Upstream references** → **keep**: the `rustdesk-org` git dependencies, the `rustdesk`/`librustdesk` crate names, `UPSTREAM-SYNC.md`'s discussion of the upstream project, and the `rustdesk-client-nemo` / `rustdesk-server-nemo` submodule paths. Scrubbing these loses the provenance we need to keep merging upstream.

Do **17** first: it delivers the thing actually complained about (searchability) at a fraction of the risk.

---

## LOW — polish / housekeeping

### 12. Settings dialog: swap **Alias** and **Direct IP access** between sections  *(DONE 2026-10-16, client `nemo-tdd`)*
Alias now sits under **Allgemein**, direct IP access (and its port row) under **Sicherheit & Netzwerk**, next to the IP whitelist that gates it. Not screenshot-verified — the Sciter UI cannot be built from the Linux dev box.
User request 2026-09-02, in `index.tis` `NemoSettingsDialog.render()`:
- **Alias** (`aRow("nemo-alias", …)`) moves from "Sicherheit & Netzwerk" (`sec`) → "Allgemein" (`gen`) — it's a friendly display name, not a security setting.
- **Direkten IP-Zugang aktivieren** (`tRow("direct-server", …)` + its dependent `aRow("edit-direct-port")`) moves from "Allgemein" (`gen`) → "Sicherheit & Netzwerk" (`sec`) — it IS a network/exposure setting.

### 13. About-dialog placeholder links  *(HANDLED 2026-10-16; still needs the real URLs)*
The three rows are now **omitted** rather than shown as "(wird ergänzt)" — a dialog that names a support channel and then says the address is missing is worse than one that does not mention it, because the reader cannot tell "not set up yet" from "we lost the page". Fill `NEMO_ABOUT_LINKS` in `index.tis` `showAbout()` (one array, label + URL; an empty URL hides its row) and the rows come back as real clickable links through the wiring that was already there. **What is still needed from TBF: the website URL, the support contact, the privacy-statement URL.**

### 14. `%APPDATA%` dir rebrand (deferred, cosmetic)
`APP_NAME` stays `RustDesk` so config dir/service/registry are unchanged; a true rename needs a config-migration step. **Not cosmetic any more in one respect:** the same constant is why Windows cannot find the app as "TBFDesk" — see **17**, which fixes the searchable name *without* this migration.

### 15. Inherited upstream code markers (informational)
- server `utils.rs:97/109/119` (OSX reverse-DNS, "ICMP ping?", "key check"); `rendezvous_server.rs:284` (`unreachable!()?`), `:1505` (udp self-poll workaround).
- client `client.rs:4138/4173` (socket-reuse micro-opt), `client.rs:122/3362` (Wayland login screen, upstream limitation).

---

## ✅ Recently closed (kept for context)
- **2026-09-02:** reload-icon root cause (onSize `max-width:0`); auto-update interval option + row dormant; About rebranded to TBF; **admin policy delivered user-overridable** (admins edit any setting locally; deployed); build-version readout (left pane + login gate); 176 checkout reconciled; LDAP service account **confirmed set** (`mstep@tbfgmbh.local`) — directory picker unblocked.
- **2026-09-02 (earlier):** encrypted direct-IP (B) + S-A fail-closed; require-encrypted fleet-wide; H1/M3/M4; 1% bitrate; multi-screen tiled view; settings modal dialog.

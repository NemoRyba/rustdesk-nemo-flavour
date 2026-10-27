# RustDesk Nemo Flavour

Company-focused RustDesk fork workspace for high-performance remote access to CAD/3D workstations.

> **Continuing this work?** Start with [`ARCHITECTURE-WIRE.md`](ARCHITECTURE-WIRE.md) — what talks to what,
> which cipher protects which leg, and where the gaps are, every claim checked at the call site. Its
> interactive companion is `wire-schematic.html` (four cases, hover anything for detail).
> Then [`HANDOFF.md`](HANDOFF.md) for build/deploy recipes and the **screenshot-self-verify** method for the
> client UI (PrintWindow — no focus steal), and [`DEPLOY.md`](DEPLOY.md) for running it.
>
> Working on this with a local model? Start with [`RUNBOOK-LOCAL-MODEL.md`](RUNBOOK-LOCAL-MODEL.md) (build, test, lab, VMs, GUI control).
>
> Deploying this yourself? [`DEPLOYMENT-STEP-BY-STEP.md`](DEPLOYMENT-STEP-BY-STEP.md) is the short, ordered version; [`DEPLOY.md`](DEPLOY.md) has the full detail.
>
> The open-items register is `../OPEN-POINTS-2026-09-21.md` (outside this repo; see *Known gaps* below).
> `OPEN-TODOS.md` and `SECURITY-HARDENING-TODO.md` predate the September verification sweep and contain
> items that have since been fixed, reverted, or found to be wrong — treat them as history, not as a list.
>
> The running client shows its **build id** (git hash + date) bottom-left, so you can always tell which
> build you're looking at.

## Repositories

- `rustdesk-client-nemo`: RustDesk open-source client fork.
- `rustdesk-server-nemo`: RustDesk open-source server fork.

## Current Direction

- **Sessions are relayed, and that is not currently a choice.** The intent was direct-first with relay
  as fallback. Verified against the code, three independent things prevent a direct session for a
  technician on the internet: the shipped systemd unit passes `--mask`, so hbbs forces the relay and
  rewrites the NAT type to `SYMMETRIC`; `PunchHoleResponse.socket_addr` is the address hbbs *observes*,
  and hbbs is on site, so it hands out a `192.168.x.y`; and UDP punching is deliberately not implemented
  server-side (an anti-amplification port from upstream). Fixing any one alone changes nothing.
- **IPv6 is the one lever that works**, and it needs no new code — the field is already carried end to
  end, and the client attempts v6 *before* it checks whether the server forced a relay, so it survives
  `--mask`. It needs a delegated prefix through both routers. See `ARCHITECTURE-WIRE.md` and
  `../vm/shots/DESIGN-direct-path-analysis.md` §7.
- **Direct buys resilience, not frame rate.** The relay is on site, so the thin uplink is crossed once
  either way. What direct removes is a shared bottleneck and a single point of failure, and the server's
  NIC carrying every workstation's video.
- Performance work belongs on *bytes over the uplink*, not on the local hop: the workstations are strong,
  the internet is not.
- Keep the existing 3D AutoCAD mouse forwarding solution available for later integration.

## Implemented (TBFDesk management layer)

Server-driven management on top of RustDesk, administered from the server dashboard
(`https://<server>:21120/nemo/admin`, branded **TBFDesk Admin**):

- **LDAP/AD login** (server-side, over LDAPS with certificate pinning): clients log in
  with Windows-domain credentials and receive a server-populated **address book**
  filtered per user. HTTPS on the management/login API so credentials never travel in
  cleartext.
- **Login-first client**: when login is required, the client shows only a sign-in
  prompt until an authorized user signs in; a stale session self-heals on the next poll.
- **ACL tab + Directory-users picker**: search the AD domain and tick which users may
  use TBFDesk (directory browse needs a read-only service account: a Bind DN + password
  in Integration → LDAP). Only selected users can sign in; login attempts by others do
  not populate the allowlist.
- **Per-user policy + connection ACL** enforced server-side at the rendezvous punch
  (not just address-book visibility).
- **Address book shows ID + hostname**: each host reports its hostname via its signed
  policy poll, so an operator can tell which computer an ID is.
- Managed (signed) client policy, global client defaults, per-user session permissions,
  and an adjustable 1/2/3-column dashboard layout.
- **Admin exception:** a logged-in admin receives the policy as *defaults only*
  (`allow_user_override` forced true on delivery) and can change any setting locally.
- **Layer 1 — pinned device keys.** Every machine holds an Ed25519 private key minted on the server and
  bound to its peer id. It is proven on *every* rendezvous connection, by both technicians and
  workstations — the same code path, the same checks, no role branch. `require_device_key` defaults on,
  so a client without one is refused outright. This, not the LDAP login, is the control the deployment
  rests on.
- **One-paste client setup.** The dashboard hands out a **setup string** carrying everything
  a fresh client cannot reach the server without — ID/rendezvous server, relay, api-server
  and management URL, the server's identity key and its certificate fingerprint — and,
  when generated together with a device key, that key as well. Exported **twice**, for
  inside the network and from the internet, because the server has two addresses and a
  client carries one set; the public one is never derived from the dashboard's own
  address, so an operator working over the LAN cannot bake a LAN address into it. The client's *Import device
  key* dialog takes either one (or loads the downloaded file), and
  `tbfdesk --import-setup` does the same unattended. It is the client's trust anchor, so
  it is moved like a password, not like a config file.
- **First-use binding, with operator confirmation** (not deployed yet, see
  [DEVICE-KEY-CLAIM.md](DEVICE-KEY-CLAIM.md)). A key generated *without* an id is a one-shot
  provisioning token: the first client that proves it is **still refused** and files a claim the operator
  confirms in the dashboard, which is what resolves the deadlock where a key wants an id that a client
  cannot show until it is past its provisioning gate. The signature proves possession of the key; the
  reported id is self-asserted, so a human attests the pairing. A pending claim grants nothing, which
  makes it double as the "a client is here, unverified" view the dashboard never had.
- Settings as a modal dialog (DE/EN, plain-language tooltips), address-book reload
  button, multi-screen tiled view, build-id readout bottom-left.

## Known gaps

Not everything above is as strong as it sounds, and the fork is explicit about which parts are not.
`ARCHITECTURE-WIRE.md` carries the full list with the condition attached to each; the ones worth knowing
before reading any other document:

- **Direct-IP (`host:port`) is plaintext and unauthenticated**, not encrypted. `client.rs:335` returns a
  bare socket for an IP peer and never calls `secure_connection`. It is off by default (`direct-server`)
  and currently non-functional as well, but the README previously claimed the opposite.
- **Direct-IP-by-address sessions never negotiate a key.** `Client::_start` returns a bare TCP stream
  for an `<ip>` or `<host>:<port>` peer without calling `secure_connection`, and `nemo-peer-keys` is
  keyed by TBFDesk id, so there is nothing to anchor an address to. With `nemo-require-encrypted-session`
  now ON by default the controlled side refuses such a connection rather than serving it in the clear,
  so the path is closed rather than encrypted. `direct-server` is off by default.
- ~~Port-forward / RDP tunnels are plaintext~~ — fixed 2026-09-27: the tunnel stays encrypted. Both ends
  must run the same client version for port forwarding.
- **Layer 2 (LDAP) is off at shipped defaults** (`require_login` is `false`), so a logged-out technician
  whose machine holds a valid device key can still connect. Layer 1 is on; Layer 2 is opt-in.
- **The management API is off at bare defaults** (`nemo-api` defaults `N`, bound to loopback). The
  committed systemd unit is what turns it on as HTTPS on `0.0.0.0:21120`.

The ranked register of open items lives in `../OPEN-POINTS-2026-09-21.md`, outside this repository —
moving it in is itself an open item. `OPEN-TODOS.md` and `TODO.md` are older running logs.

## Security posture & penetration test

An authorized, lab-only **assumed-breach penetration test** was run against the full server↔client
system — white-box (the tester had the protocol design and a network/endpoint position) but with
**no private keys, admin token or user password**. Full package and per-scenario results in
[`pentest/`](pentest/) → [`pentest/FINDINGS.md`](pentest/FINDINGS.md).

**Outcome: no BREAK.** Across passive capture, active MITM with a rogue cert (pin present and
cleared), policy replay/rollback, direct-session control-ticket forgery, knock/SPA
(replay/forge/scan), rendezvous/relay, the update path, and the management-API auth, every security
property held. **Residual real-world exposures (not breaks):** the direct port is reachable
intra-LAN (gated by the control-ticket layer), and a full local-root compromise of a provisioned
client can read that machine's own device key + in-memory knock keys. Ranked remediation:
[`pentest/07-HARDENING.md`](pentest/07-HARDENING.md); implementation backlog with status:
[`pentest/08-IMPROVEMENTS.md`](pentest/08-IMPROVEMENTS.md).

**Hardening implemented since (server, from the backlog):** **C1** — pre-gate per-source rate limit
on the unauthenticated mgmt-API routes (429 before any unseal); **C3** — `require_auth` as a
route-layer on every `/nemo/api/*` admin route (401 before body parse, no field-name leak); **C4** —
an operator **Security panel** in `/nemo/admin` (metrics, anomaly log, per-entry Unblock/Reset/Clear
for auto-blocked sources — operator guide: [`SECURITY-PANEL.md`](SECURITY-PANEL.md)). 119/119 server
tests pass; all runtime-verified. C2 and C5–C9 remain open.

## Releases & uninstaller

Installers for client and server ship as GitHub releases on this (private) superproject. Latest —
**`release-2026-10-26`**: Windows `tbfdesk-1.4.16-x64-install.exe`, Debian/Ubuntu `.deb`, Arch
`.pkg.tar.zst`, a generic Linux client tarball, and the hardened server tarball (`hbbs`+`hbbr`
1.1.15), each with a `.sha256`. (The `.deb`/generic Linux client are VP8/VP9/AV1 only — no hwcodec
H.264/H.265 yet; the Windows installer and Arch package do have it. See OPEN-TODOS.)

A **selective uninstaller** ships with both client and server (`rustdesk-client-nemo/res/uninstall/`,
`rustdesk-server-nemo/scripts/uninstall/`): a GUI checklist (zenity/kdialog on Linux, WinForms on
Windows) plus a headless mode, to cleanly remove an install and optionally wipe settings, the device
ID + keypair, the device key/secrets and — for the server — the signing keys, DB and policy state,
so the next install comes up fresh. Verified end-to-end on the lab.

## Build Priority

1. Validate server build on Linux.
2. Validate Linux client build on Linux/Docker.
3. Establish a reproducible Windows client build path, likely pinned CI or Docker-based cross build if supported.

## Ubuntu Build Notes

On Ubuntu 24.04, the Linux client can build without vcpkg by installing `libvpx-dev`, `libyuv-dev`, `libopus-dev`, and `libaom-dev`, then using:

```sh
PKG_CONFIG_PATH="$PWD/../pkgconfig" cargo build --features linux-pkg-config
```

The local `pkgconfig/libyuv.pc` shim is needed because Ubuntu's `libyuv-dev` package installs headers/libs but no `libyuv.pc`.

Server release build:

```sh
cd rustdesk-server-nemo
cargo build --release
```

Linux client debug build:

```sh
cd rustdesk-client-nemo
PKG_CONFIG_PATH="$PWD/../pkgconfig" cargo build --features linux-pkg-config
```

## Windows Client Build Notes

The working Windows client is the **Sciter** build (`--features inline`), not Flutter.
Build, stage, and run it with the helper script from the workspace root:

```powershell
.\build-run-windows-client.ps1            # build + stage to run-windows-client\ + launch
.\build-run-windows-client.ps1 -NoRun     # build + stage only (no launch)
```

The script regenerates the inline Sciter UI (`python res\inline-sciter.py`), then runs
`cargo build --release --features inline`, and stages the binary plus `sciter.dll` into
`run-windows-client\`. It is fingerprint-gated (rebuilds only when tracked sources
change) and needs `VCPKG_ROOT` (bundled under `tools\`) and `LIBCLANG_PATH` (set by the
script). Rust **1.75** is required for the Sciter bindings.

The Flutter CI workflows in the client fork (`Flutter Nightly/Tag/Full`) remain available
for the upstream Flutter path, but that is not the path used here.

### Linux controlled host on the server VM (192.168.1.14)

The persistent Linux host (`rustdesk-nemo.service` → `/opt/nemo-rustdesk/rustdesk`) is
built with the Ubuntu notes above and Rust 1.75:

```sh
cd rustdesk-client-nemo
PKG_CONFIG_PATH="$PWD/../pkgconfig" cargo +1.75.0 build --features "inline,linux-pkg-config"
```

Deploy by atomic-replacing the binary (keep a `.bak`) and `systemctl restart
rustdesk-nemo.service`.

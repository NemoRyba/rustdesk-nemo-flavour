# RustDesk Nemo Flavour

Company-focused RustDesk fork workspace for high-performance remote access to CAD/3D workstations.

> **Continuing this work?** Read [`HANDOFF.md`](HANDOFF.md) first — current state, build/deploy recipes, and the **screenshot-self-verify** method for the client UI (PrintWindow — no focus steal). The ranked, **verified** TODO list lives in [`OPEN-TODOS.md`](OPEN-TODOS.md) (each item checked against code/live state 2026-09-02); transport-security detail in [`SECURITY-HARDENING-TODO.md`](SECURITY-HARDENING-TODO.md). The running client shows its **build id** (git hash + date) bottom-left, so you can always tell which build you're looking at.

## Repositories

- `rustdesk-client-nemo`: RustDesk open-source client fork.
- `rustdesk-server-nemo`: RustDesk open-source server fork.

## Current Direction

- Prefer direct workstation connections for AutoCAD/3D work.
- Use relay only as fallback.
- Evaluate WireGuard/direct IP access as the main production topology.
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
- **Encrypted direct-IP** with server-anchored peer keys; `require-encrypted-session`
  enforced fleet-wide (no plaintext fallback).
- Settings as a modal dialog (DE/EN, plain-language tooltips), address-book reload
  button, multi-screen tiled view, build-id readout bottom-left.

See [`OPEN-TODOS.md`](OPEN-TODOS.md) for the ranked, verified open items
(`TODO.md` is the older running log).

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

### 176 Linux controlled host

The persistent Linux host (`rustdesk-nemo.service` → `/opt/nemo-rustdesk/rustdesk`) is
built with the Ubuntu notes above and Rust 1.75:

```sh
cd rustdesk-client-nemo
PKG_CONFIG_PATH="$PWD/../pkgconfig" cargo +1.75.0 build --features "inline,linux-pkg-config"
```

Deploy by atomic-replacing the binary (keep a `.bak`) and `systemctl restart
rustdesk-nemo.service`.

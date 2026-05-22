# RustDesk Nemo Flavour

Company-focused RustDesk fork workspace for high-performance remote access to CAD/3D workstations.

## Repositories

- `rustdesk-client-nemo`: RustDesk open-source client fork.
- `rustdesk-server-nemo`: RustDesk open-source server fork.

## Current Direction

- Prefer direct workstation connections for AutoCAD/3D work.
- Use relay only as fallback.
- Evaluate WireGuard/direct IP access as the main production topology.
- Keep the existing 3D AutoCAD mouse forwarding solution available for later integration.

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

RustDesk's current Windows client build path is Windows-native rather than Ubuntu cross-compile. The upstream workflow in `rustdesk-client-nemo/.github/workflows/flutter-build.yml` runs on `windows-2022` with:

- Rust `1.75` and target `x86_64-pc-windows-msvc`
- Flutter `3.24.5` with RustDesk's custom Windows Flutter engine
- vcpkg triplet `x64-windows-static`
- MSBuild/MSI packaging and Windows driver artifacts

For reproducible Windows artifacts, use the existing GitHub Actions workflows in the client fork:

- `Flutter Nightly Build` for unsigned nightly artifacts.
- `Flutter Tag Build` for release/tag artifacts.
- `Full Flutter CI` for validation without uploading artifacts.

The core Windows command used by the workflow is:

```powershell
python3 .\build.py --portable --hwcodec --flutter --vram --skip-portable-pack
```

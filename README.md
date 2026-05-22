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

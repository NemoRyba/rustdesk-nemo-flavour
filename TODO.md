# RustDesk Nemo TODO

## Later Integration

- Integrate the existing separate VPN-based 3D AutoCAD mouse solution into the RustDesk-based all-in-one remote workstation setup.
  - Current state: separate working solution exists and is used in production.
  - Reason: 3D AutoCAD mouse support did not work reliably in the tested remote desktop products.
  - Next input needed: implementation details/protocol/device handling from the current solution.

## Current Focus

- Establish the best network topology for high-performance direct RustDesk access to workstation PCs.
- Avoid relay paths for AutoCAD/3D work unless used only as a fallback.
- Validate client/server builds in a Linux VM or Docker before returning to Windows packaging.

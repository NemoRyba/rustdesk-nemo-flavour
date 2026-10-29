#!/usr/bin/env bash
# Build the TBFDesk server tarball (hbbs/hbbr + installer + units + uninstaller) from
# the current release binaries. This replaces the ad-hoc heredoc that produced the
# 1.1.15 tarball, so the installer (rustdesk-server-nemo/dist/install.sh) is now
# version-controlled and every release carries the upgrade-safe, path-syncing install.sh.
#
#   pkg-server.sh <version> <out-dir>
#
# Binaries default to rustdesk-server-nemo/target/release/{hbbs,hbbr}; override with
# HBBS=<path> HBBR=<path>. For a portable generic-linux tarball, build them on the oldest
# distro you must support (see scripts/build-ubuntu-server-release.sh for the Ubuntu path).
set -euo pipefail
VER="${1:?version}"; OUT="${2:?out dir}"
S=/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-server-nemo
HBBS="${HBBS:-$S/target/release/hbbs}"
HBBR="${HBBR:-$S/target/release/hbbr}"
mkdir -p "$OUT"
for b in "$HBBS" "$HBBR"; do [ -f "$b" ] || { echo "missing binary: $b" >&2; exit 1; }; done

NAME="tbfdesk-server-$VER-linux-x86_64"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/$NAME"
install -d "$ROOT/bin" "$ROOT/systemd" "$ROOT/uninstall"

# binaries (stripped copies; leave the originals intact)
install -m755 "$HBBS" "$ROOT/bin/hbbs"
install -m755 "$HBBR" "$ROOT/bin/hbbr"
strip "$ROOT/bin/hbbs" "$ROOT/bin/hbbr" 2>/dev/null || true

# installer (the committed, upgrade-safe one) + the TBFDesk units
install -m755 "$S/dist/install.sh" "$ROOT/install.sh"
install -m644 "$S/systemd/rustdesk-hbbs-nemo.service" "$ROOT/systemd/"
install -m644 "$S/systemd/rustdesk-hbbr-nemo.service" "$ROOT/systemd/"

# selective uninstaller (same scripts shipped with the client)
install -m755 "$S/scripts/uninstall/tbfdesk-uninstall.sh"  "$ROOT/uninstall/"
install -m644 "$S/scripts/uninstall/tbfdesk-uninstall.ps1" "$ROOT/uninstall/"
[ -f "$S/scripts/uninstall/README.md" ] && install -m644 "$S/scripts/uninstall/README.md" "$ROOT/uninstall/"

# README (version-stamped)
cat > "$ROOT/README.md" <<EOF
# TBFDesk server $VER (Linux x86_64)
hbbs/hbbr with the Nemo hardening (device-key gate, sealed login, mgmt API with the
C1 pre-gate rate limit, C3 auth-before-parse, C4 Security panel).

Install / upgrade: ./install.sh      (keeps the unit's ExecStart in sync with the binary
                                       path, so upgrades never need re-pointing)
Config:            /etc/tbfdesk/hbbs.env   (NEMO_API_TOKEN, TBFDESK_RELAY, TBFDESK_MASK)
Uninstall / reset: ./uninstall/tbfdesk-uninstall.sh server
EOF

TARBALL="$OUT/$NAME.tar.gz"
( cd "$WORK" && tar --owner=0 --group=0 -czf "$TARBALL" "$NAME" )
echo "built $TARBALL ($(du -h "$TARBALL" | cut -f1))"
( cd "$OUT" && sha256sum "$NAME.tar.gz" | tee "$NAME.tar.gz.sha256" )

#!/usr/bin/env bash
# Build the TBFDesk Linux packages (.deb, .pkg.tar.zst) from the current release binary.
# No dpkg-deb/rpmbuild needed: the .deb is assembled with ar + tar, the Arch pkg with makepkg.
#   pkg-linux.sh <version> <out-dir>
#
# IMPORTANT (cross-distro): the .deb must be built from a binary compiled ON Debian/Ubuntu
# (an Arch-built binary links Arch sonames like libvpx.so.12 that Debian lacks). Build the
# Linux client in the ubuntu 24.04 container (localhost/nemo-gui) with features
# inline,linux-pkg-config; libyuv has no .pc on Ubuntu, so provide one via a /pkgcfg dir on
# PKG_CONFIG_PATH (see pentest/... no -- see the release build log / memory). Then run this
# with PKG_BIN=<that binary>. The .pkg.tar.zst is built from the host (Arch) binary.
set -euo pipefail
VER="${1:?version}"; OUT="${2:?out dir}"
C=/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo
BIN="${PKG_BIN:-/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/target/release/rustdesk}"
SCITER=/usr/lib/libsciter-gtk.so
mkdir -p "$OUT"
[ -f "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }
strings "$BIN" | grep -qF "$VER" || echo "WARN: binary does not contain the string $VER"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- common install tree (matches build.py's sciter-deb layout) --------------
stage() {  # $1 = root
  local R="$1"
  install -Dm755 "$BIN" "$R/usr/share/rustdesk/rustdesk"
  strip "$R/usr/share/rustdesk/rustdesk" 2>/dev/null || true
  install -Dm644 "$SCITER" "$R/usr/share/rustdesk/libsciter-gtk.so"
  install -Dm644 "$C/res/rustdesk.service" "$R/usr/share/rustdesk/files/systemd/rustdesk.service"
  install -Dm644 "$C/res/128x128@2x.png" "$R/usr/share/icons/hicolor/256x256/apps/rustdesk.png"
  install -Dm644 "$C/res/scalable.svg" "$R/usr/share/icons/hicolor/scalable/apps/rustdesk.svg"
  install -Dm644 "$C/res/rustdesk.desktop" "$R/usr/share/applications/rustdesk.desktop"
  [ -f "$C/res/rustdesk-link.desktop" ] && install -Dm644 "$C/res/rustdesk-link.desktop" "$R/usr/share/applications/rustdesk-link.desktop" || true
}

# ---- .deb (ar + tar) ---------------------------------------------------------
DEB_ROOT="$WORK/deb"; stage "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN"
cp -a "$C/res/DEBIAN/"* "$DEB_ROOT/DEBIAN/"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: tbfdesk
Section: net
Priority: optional
Version: $VER
Architecture: amd64
Maintainer: TBFDesk <noreply@tbfdesk.local>
Homepage: https://github.com/NemoRyba/rustdesk-client-nemo
Provides: rustdesk
Conflicts: rustdesk
Replaces: rustdesk
Depends: libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libgdk-pixbuf-2.0-0, libcairo2, libx11-6, libxfixes3, libxtst6, libxcb1, libxcb-randr0, libxcb-shm0, libxkbcommon0, libdbus-1-3, libpam0g, libpulse0, libopus0, libvpx9, libaom3, libyuv0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0
Recommends: libayatana-appindicator3-1
Description: TBFDesk remote control (RustDesk-based, centrally managed).
EOF
# md5sums
( cd "$DEB_ROOT" && find usr etc -type f 2>/dev/null -exec md5sum {} \; | sed 's# # /#2' > DEBIAN/md5sums ) || true
# build members (control first inside control.tar is conventional; order in ar matters)
( cd "$DEB_ROOT/DEBIAN" && tar --owner=0 --group=0 -czf "$WORK/control.tar.gz" ./* )
( cd "$DEB_ROOT" && tar --owner=0 --group=0 -czf "$WORK/data.tar.gz" ./usr ./etc 2>/dev/null || tar --owner=0 --group=0 -czf "$WORK/data.tar.gz" ./usr )
printf '2.0\n' > "$WORK/debian-binary"
DEB="$OUT/tbfdesk-$VER-amd64.deb"
( cd "$WORK" && ar rc "$DEB" debian-binary control.tar.gz data.tar.gz )
echo "built $DEB ($(du -h "$DEB" | cut -f1))"

# ---- .pkg.tar.zst (makepkg) --------------------------------------------------
PKGDIR="$WORK/arch"; mkdir -p "$PKGDIR"
ARCH_ROOT="$PKGDIR/pkgroot"; stage "$ARCH_ROOT"
install -Dm644 "$ARCH_ROOT/usr/share/rustdesk/files/systemd/rustdesk.service" "$ARCH_ROOT/usr/lib/systemd/system/rustdesk.service"
ln -sf /usr/share/rustdesk/rustdesk "$ARCH_ROOT/usr/bin/tbfdesk" 2>/dev/null || true
mkdir -p "$ARCH_ROOT/usr/bin"; ln -sf /usr/share/rustdesk/rustdesk "$ARCH_ROOT/usr/bin/rustdesk"
cat > "$PKGDIR/PKGBUILD" <<EOF
pkgname=tbfdesk
pkgver=${VER//-/_}
pkgrel=1
pkgdesc="TBFDesk remote control (RustDesk-based, centrally managed)"
arch=('x86_64')
url="https://github.com/NemoRyba/rustdesk-client-nemo"
license=('AGPL3')
provides=('rustdesk')
conflicts=('rustdesk')
depends=('gtk3' 'libxcb' 'xdotool' 'libxfixes' 'alsa-lib' 'systemd-libs' 'curl' 'libva' 'pipewire' 'pam')
options=('!strip' '!debug')
package() { cp -a "$ARCH_ROOT/." "\$pkgdir/"; }
EOF
( cd "$PKGDIR" && PKGDEST="$OUT" PKGEXT='.pkg.tar.zst' makepkg -f --nodeps --noconfirm >/tmp/makepkg.log 2>&1 ) \
  && mv "$OUT"/tbfdesk-*.pkg.tar.zst "$OUT/tbfdesk-$VER-x86_64.pkg.tar.zst" 2>/dev/null || true
ls "$OUT"/tbfdesk-"$VER"-x86_64.pkg.tar.zst 2>/dev/null && echo "built the Arch package" || { echo "makepkg failed:"; tail -8 /tmp/makepkg.log; }

echo "--- sha256:"
( cd "$OUT" && for f in tbfdesk-$VER-amd64.deb tbfdesk-$VER-x86_64.pkg.tar.zst; do [ -f "$f" ] && sha256sum "$f" | tee "$f.sha256"; done )

#!/usr/bin/env bash
# Build the TBFDesk FLUTTER Linux packages: tbfdesk-flutter-<v>-amd64.deb (from a bundle
# built ON Ubuntu 24.04), tbfdesk-flutter-<v>-x86_64.pkg.tar.zst and
# tbfdesk-flutter-client-<v>-linux-x86_64.tar.gz (from a bundle built on the Arch host).
# The Sciter packages are dist/pkg-linux.sh.
#
#   DEB_BUNDLE=<ubuntu bundle dir> ARCH_BUNDLE=<arch bundle dir> pkg-linux-flutter.sh <version> <out-dir>
#
# Both UIs install the same TBFDesk (/usr/share/rustdesk, /usr/bin/rustdesk, the rustdesk
# service, the same config): the Flutter package REPLACES the Sciter one and the other way
# round, so installing the other package switches a machine's UI and keeps its ID, keys and
# configuration. A bundle = flutter/build/linux/x64/release/bundle with lib/librustdesk.so.
# The .deb carries an uncompressed `_tbfdesk_ui` member (dpkg ignores members starting with
# "_") so the management server can tell it from the Sciter .deb on upload.
set -euo pipefail
VER="${1:?version}"; OUT="${2:?out dir}"
C=/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo
DEB_BUNDLE="${DEB_BUNDLE:?DEB_BUNDLE = bundle built on Ubuntu 24.04}"
ARCH_BUNDLE="${ARCH_BUNDLE:?ARCH_BUNDLE = bundle built on the Arch host}"
mkdir -p "$OUT"
for b in "$DEB_BUNDLE" "$ARCH_BUNDLE"; do
  for f in rustdesk lib/librustdesk.so lib/libapp.so data/flutter_assets; do
    [ -e "$b/$f" ] || { echo "missing $b/$f" >&2; exit 1; }
  done
  grep -qaF "$VER" "$b/lib/librustdesk.so" || echo "WARN: $b/lib/librustdesk.so does not contain the string $VER"
done
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

stage() {  # $1 = root, $2 = bundle
  local R="$1" B="$2"
  install -d "$R/usr/share/rustdesk"
  cp -a "$B"/. "$R/usr/share/rustdesk/"
  strip "$R/usr/share/rustdesk/rustdesk" "$R/usr/share/rustdesk/lib/librustdesk.so" 2>/dev/null || true
  install -Dm644 "$C/res/rustdesk.service" "$R/usr/share/rustdesk/files/systemd/rustdesk.service"
  install -Dm644 "$C/res/128x128@2x.png" "$R/usr/share/icons/hicolor/256x256/apps/rustdesk.png"
  install -Dm644 "$C/res/scalable.svg" "$R/usr/share/icons/hicolor/scalable/apps/rustdesk.svg"
  install -Dm644 "$C/res/rustdesk.desktop" "$R/usr/share/applications/rustdesk.desktop"
  [ -f "$C/res/rustdesk-link.desktop" ] && install -Dm644 "$C/res/rustdesk-link.desktop" "$R/usr/share/applications/rustdesk-link.desktop" || true
}

# ---- .deb --------------------------------------------------------------------------
DEB_ROOT="$WORK/deb"; stage "$DEB_ROOT" "$DEB_BUNDLE"
mkdir -p "$DEB_ROOT/DEBIAN"
cp -a "$C/res/DEBIAN/"* "$DEB_ROOT/DEBIAN/"
DEPENDS="${DEB_DEPENDS:-libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libgdk-pixbuf-2.0-0, libcairo2, libpango-1.0-0, libepoxy0, libx11-6, libxfixes3, libxtst6, libxcb1, libxcb-randr0, libxcb-shm0, libxkbcommon0, libdbus-1-3, libpam0g, libpulse0, libopus0, libvpx9, libaom3, libyuv0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libstdc++6}"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: tbfdesk-flutter
Section: net
Priority: optional
Version: $VER
Architecture: amd64
Maintainer: TBFDesk <noreply@tbfdesk.local>
Homepage: https://github.com/NemoRyba/rustdesk-client-nemo
Provides: rustdesk
Conflicts: rustdesk, tbfdesk
Replaces: rustdesk, tbfdesk
Depends: $DEPENDS
Recommends: libayatana-appindicator3-1
Description: TBFDesk remote control, Flutter UI (RustDesk-based, centrally managed).
 Installs the same TBFDesk as the Sciter package (tbfdesk) and replaces it.
EOF
( cd "$DEB_ROOT" && find usr -type f -exec md5sum {} \; | sed 's# # /#2' > DEBIAN/md5sums )
( cd "$DEB_ROOT/DEBIAN" && tar --owner=0 --group=0 -czf "$WORK/control.tar.gz" ./* )
( cd "$DEB_ROOT" && tar --owner=0 --group=0 -czf "$WORK/data.tar.gz" ./usr )
printf '2.0\n' > "$WORK/debian-binary"
printf 'tbfdesk_ui = "flutter"\n' > "$WORK/_tbfdesk_ui"
DEB="$OUT/tbfdesk-flutter-$VER-amd64.deb"; rm -f "$DEB"
( cd "$WORK" && ar rc "$DEB" debian-binary control.tar.gz data.tar.gz _tbfdesk_ui )
echo "built $DEB ($(du -h "$DEB" | cut -f1))"

# ---- .pkg.tar.zst --------------------------------------------------------------------
PKGDIR="$WORK/arch"; mkdir -p "$PKGDIR"
ARCH_ROOT="$PKGDIR/pkgroot"; stage "$ARCH_ROOT" "$ARCH_BUNDLE"
install -Dm644 "$ARCH_ROOT/usr/share/rustdesk/files/systemd/rustdesk.service" "$ARCH_ROOT/usr/lib/systemd/system/rustdesk.service"
mkdir -p "$ARCH_ROOT/usr/bin"; ln -sf /usr/share/rustdesk/rustdesk "$ARCH_ROOT/usr/bin/rustdesk"; ln -sf /usr/share/rustdesk/rustdesk "$ARCH_ROOT/usr/bin/tbfdesk"
cat > "$PKGDIR/PKGBUILD" <<EOF
pkgname=tbfdesk-flutter
pkgver=${VER//-/_}
pkgrel=1
pkgdesc="TBFDesk remote control, Flutter UI (RustDesk-based, centrally managed)"
arch=('x86_64')
url="https://github.com/NemoRyba/rustdesk-client-nemo"
license=('AGPL3')
provides=('rustdesk')
conflicts=('rustdesk' 'tbfdesk')
replaces=('tbfdesk')
depends=('gtk3' 'libxcb' 'xdotool' 'libxfixes' 'alsa-lib' 'systemd-libs' 'curl' 'libva' 'pipewire' 'pam' 'libepoxy')
options=('!strip' '!debug')
package() { cp -a "$ARCH_ROOT/." "\$pkgdir/"; }
EOF
( cd "$PKGDIR" && PKGDEST="$OUT" PKGEXT='.pkg.tar.zst' makepkg -f --nodeps --noconfirm > "$WORK/makepkg.log" 2>&1 ) \
  && mv "$OUT/tbfdesk-flutter-${VER//-/_}-1-x86_64.pkg.tar.zst" "$OUT/tbfdesk-flutter-$VER-x86_64.pkg.tar.zst" \
  || { echo "makepkg failed:"; tail -8 "$WORK/makepkg.log"; }
[ -f "$OUT/tbfdesk-flutter-$VER-x86_64.pkg.tar.zst" ] && echo "built the Arch package"

# ---- generic tarball -----------------------------------------------------------------
TGZ="tbfdesk-flutter-client-$VER-linux-x86_64"; TR="$WORK/$TGZ"
mkdir -p "$TR"; cp -a "$ARCH_BUNDLE" "$TR/bundle"
mkdir -p "$TR/uninstall"
cp "$C"/res/uninstall/{tbfdesk-uninstall.sh,tbfdesk-uninstall.ps1,tbfdesk-uninstaller.desktop,README.md} "$TR/uninstall/"
chmod 755 "$TR/uninstall/tbfdesk-uninstall.sh"
cat > "$TR/install.sh" <<'EOF'
#!/usr/bin/env bash
# TBFDesk Flutter client installer (Linux, generic). Puts the Flutter bundle where the
# packages put it (/usr/share/rustdesk) and links /usr/bin/rustdesk; an existing TBFDesk
# (Sciter or Flutter) is replaced, its configuration in ~/.config/tbfdesk is kept.
set -euo pipefail
cd "$(dirname "$0")"
sudo rm -rf /usr/share/rustdesk.new && sudo cp -a bundle /usr/share/rustdesk.new
[ -d /usr/share/rustdesk ] && sudo rm -rf /usr/share/rustdesk.old && sudo mv /usr/share/rustdesk /usr/share/rustdesk.old
sudo mv /usr/share/rustdesk.new /usr/share/rustdesk && sudo rm -rf /usr/share/rustdesk.old
sudo ln -sf /usr/share/rustdesk/rustdesk /usr/bin/rustdesk
sudo install -m755 uninstall/tbfdesk-uninstall.sh /usr/bin/tbfdesk-uninstall
echo "Installed (Flutter UI). Launch: rustdesk    Uninstall: tbfdesk-uninstall client"
EOF
chmod 755 "$TR/install.sh"
cat > "$TR/README.md" <<EOF
# TBFDesk client $VER (Linux x86_64, Flutter UI)
Install: ./install.sh   ·   Uninstall/clean reset: tbfdesk-uninstall client
Built on Arch; for Debian/Ubuntu use tbfdesk-flutter-$VER-amd64.deb.
EOF
( cd "$WORK" && tar --owner=0 --group=0 -czf "$OUT/$TGZ.tar.gz" "$TGZ" )
echo "built $OUT/$TGZ.tar.gz ($(du -h "$OUT/$TGZ.tar.gz" | cut -f1))"

echo "--- sha256:"
( cd "$OUT" && for f in tbfdesk-flutter-$VER-amd64.deb tbfdesk-flutter-$VER-x86_64.pkg.tar.zst $TGZ.tar.gz; do
    [ -f "$f" ] && sha256sum "$f" | tee "$f.sha256"; done )

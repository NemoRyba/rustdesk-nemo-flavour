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
# with PKG_BIN=<that binary>. The .pkg.tar.zst and the generic tarball are built from the
# HOST (Arch) binary, ARCH_BIN -- an inline build: cargo build --release --features
# inline,linux-pkg-config,hwcodec. (Until 1.4.17 both formats got PKG_BIN, so the "Arch"
# package carried the Ubuntu binary and failed on Arch with "libvpx.so.9: not found".)
set -euo pipefail
VER="${1:?version}"; OUT="${2:?out dir}"
C=/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo
BIN="${PKG_BIN:-/projects/rustdesk/rustdesk-nemo-flavour/rustdesk-client-nemo/target/release/rustdesk}"
ARCH_BIN="${ARCH_BIN:-$BIN}"
SCITER=/usr/lib/libsciter-gtk.so
mkdir -p "$OUT"
for b in "$BIN" "$ARCH_BIN"; do
  [ -f "$b" ] || { echo "missing $b" >&2; exit 1; }
  # grep the binary directly: `strings | grep -q` under pipefail reports a FAILURE on a
  # match (grep -q exits early, strings dies of SIGPIPE).
  grep -qaF "$VER" "$b" || echo "WARN: $b does not contain the string $VER"
  # A release binary must embed its UI (inline); a non-inline build loads src/ui from its cwd.
  grep -qa nemoMoreMenuPopup "$b" || { echo "$b is not an inline build (no embedded UI)" >&2; exit 1; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$(dirname "$(readlink -f "$0")")/deb-bundle-libs.sh"
. "$(dirname "$(readlink -f "$0")")/arch-depends.sh"
# ARCH_PKGREL: bump for a packaging-only fix of an already released version (pacman upgrades it)
ARCH_PKGREL="${ARCH_PKGREL:-1}"

# ---- common install tree (matches build.py's sciter-deb layout) --------------
stage() {  # $1 = root, $2 = binary
  local R="$1" B="$2"
  install -Dm755 "$B" "$R/usr/share/rustdesk/rustdesk"
  strip "$R/usr/share/rustdesk/rustdesk" 2>/dev/null || true
  install -Dm644 "$SCITER" "$R/usr/share/rustdesk/libsciter-gtk.so"
  install -Dm644 "$C/res/rustdesk.service" "$R/usr/share/rustdesk/files/systemd/rustdesk.service"
  install -Dm644 "$C/res/128x128@2x.png" "$R/usr/share/icons/hicolor/256x256/apps/rustdesk.png"
  install -Dm644 "$C/res/scalable.svg" "$R/usr/share/icons/hicolor/scalable/apps/rustdesk.svg"
  install -Dm644 "$C/res/rustdesk.desktop" "$R/usr/share/applications/rustdesk.desktop"
  [ -f "$C/res/rustdesk-link.desktop" ] && install -Dm644 "$C/res/rustdesk-link.desktop" "$R/usr/share/applications/rustdesk-link.desktop" || true
}

# ---- .deb (ar + tar) ---------------------------------------------------------
DEB_ROOT="$WORK/deb"; stage "$DEB_ROOT" "$BIN"
deb_bundle_libs "$DEB_ROOT" tbfdesk '$ORIGIN/lib' "$DEB_ROOT/usr/share/rustdesk/rustdesk"
# Depends: only packages with the SAME name on Ubuntu 24.04 and 26.04 (checked 2026-11-10);
# the codec libraries whose soname changes (libvpx9 -> libvpx12, ...) are bundled instead,
# see deb-bundle-libs.sh. libxdo3, libXi, libXcursor, libX11-xcb, libxkbcommon-x11 and
# wayland-client are dlopen()ed at run time (input, cursor, Wayland), gstreamer1.0-pipewire
# is the Wayland screen capture.
DEPENDS="${DEB_DEPENDS:-libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libgdk-pixbuf-2.0-0, libcairo2, libpango-1.0-0, libx11-6, libx11-xcb1, libxfixes3, libxtst6, libxi6, libxcursor1, libxcb1, libxcb-randr0, libxcb-shm0, libxkbcommon0, libxkbcommon-x11-0, libxdo3, libwayland-client0, libdbus-1-3, libpam0g, libpulse0, libopus0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, gstreamer1.0-pipewire, libstdc++6}"
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
Conflicts: rustdesk, tbfdesk-flutter
Replaces: rustdesk, tbfdesk-flutter
Depends: $DEPENDS
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
ARCH_ROOT="$PKGDIR/pkgroot"; stage "$ARCH_ROOT" "$ARCH_BIN"
install -Dm644 "$ARCH_ROOT/usr/share/rustdesk/files/systemd/rustdesk.service" "$ARCH_ROOT/usr/lib/systemd/system/rustdesk.service"
# (until 1.4.20-1 the tbfdesk link came before the mkdir and silently failed: no `tbfdesk` command)
mkdir -p "$ARCH_ROOT/usr/bin"; ln -sf /usr/share/rustdesk/rustdesk "$ARCH_ROOT/usr/bin/rustdesk"; ln -sf /usr/share/rustdesk/rustdesk "$ARCH_ROOT/usr/bin/tbfdesk"
ARCH_DEPS="$(arch_depends sciter "$ARCH_ROOT/usr/share/rustdesk/rustdesk")" || exit 1
arch_write_install "$PKGDIR/tbfdesk.install"
cat > "$PKGDIR/PKGBUILD" <<EOF
pkgname=tbfdesk
pkgver=${VER//-/_}
pkgrel=$ARCH_PKGREL
pkgdesc="TBFDesk remote control (RustDesk-based, centrally managed)"
arch=('x86_64')
url="https://github.com/NemoRyba/rustdesk-client-nemo"
license=('AGPL3')
provides=('rustdesk')
conflicts=('rustdesk' 'tbfdesk-flutter')
replaces=('tbfdesk-flutter')
depends=($ARCH_DEPS)
install=tbfdesk.install
options=('!strip' '!debug')
package() { cp -a "$ARCH_ROOT/." "\$pkgdir/"; }
EOF
( cd "$PKGDIR" && PKGDEST="$OUT" PKGEXT='.pkg.tar.zst' makepkg -f --nodeps --noconfirm >/tmp/makepkg.log 2>&1 ) \
  && mv "$OUT/tbfdesk-${VER//-/_}-$ARCH_PKGREL-x86_64.pkg.tar.zst" "$OUT/tbfdesk-$VER-x86_64.pkg.tar.zst" || true
# (exact makepkg name: a tbfdesk-*.pkg.tar.zst glob also matched older packages in $OUT, so
#  mv got several sources, failed, and the package stayed under makepkg's name, unchecksummed)
ls "$OUT"/tbfdesk-"$VER"-x86_64.pkg.tar.zst 2>/dev/null && echo "built the Arch package" || { echo "makepkg failed:"; tail -8 /tmp/makepkg.log; }

# ---- generic tarball (Arch binary + Sciter runtime + installer + uninstaller) -
TGZ="tbfdesk-client-$VER-linux-x86_64"; TR="$WORK/$TGZ"
install -Dm755 "$ARCH_BIN" "$TR/bin/tbfdesk"; strip "$TR/bin/tbfdesk" 2>/dev/null || true
install -Dm644 "$SCITER" "$TR/lib/libsciter-gtk.so"
mkdir -p "$TR/share" "$TR/uninstall"
cp "$C"/res/uninstall/{tbfdesk-uninstall.sh,tbfdesk-uninstall.ps1,tbfdesk-uninstaller.desktop,README.md} "$TR/uninstall/"
chmod 755 "$TR/uninstall/tbfdesk-uninstall.sh"
cat > "$TR/install.sh" <<'EOF'
#!/usr/bin/env bash
# TBFDesk client installer (Linux). Installs the binary, Sciter runtime and launchers.
set -euo pipefail
cd "$(dirname "$0")"
sudo install -m755 bin/tbfdesk /usr/bin/rustdesk
[ -f lib/libsciter-gtk.so ] && sudo install -m644 lib/libsciter-gtk.so /usr/lib/
sudo install -m644 uninstall/tbfdesk-uninstaller.desktop /usr/share/applications/ 2>/dev/null || true
sudo install -m755 uninstall/tbfdesk-uninstall.sh /usr/bin/tbfdesk-uninstall
echo "Installed. Launch: rustdesk    Uninstall (optionally wiping ID/keys/config): tbfdesk-uninstall client"
EOF
chmod 755 "$TR/install.sh"
cat > "$TR/README.md" <<EOF
# TBFDesk client $VER (Linux x86_64, Sciter UI, hwcodec)
Install: ./install.sh   ·   Uninstall/clean reset: tbfdesk-uninstall client (or ./uninstall/tbfdesk-uninstall.sh)
Note: this binary is built on Arch and links Arch sonames; for Debian/Ubuntu use the .deb.
EOF
( cd "$WORK" && tar --owner=0 --group=0 -czf "$OUT/$TGZ.tar.gz" "$TGZ" )
echo "built $OUT/$TGZ.tar.gz ($(du -h "$OUT/$TGZ.tar.gz" | cut -f1))"

echo "--- sha256:"
( cd "$OUT" && for f in tbfdesk-$VER-amd64.deb tbfdesk-$VER-x86_64.pkg.tar.zst $TGZ.tar.gz; do [ -f "$f" ] && sha256sum "$f" | tee "$f.sha256"; done )

#!/usr/bin/env bash
# depends=() for the TBFDesk Arch packages (sourced by pkg-linux.sh / pkg-linux-flutter.sh).
#
#   arch_depends sciter|flutter <ELF>...   -> prints the quoted depends entries
#
# Until 1.4.20-1 the list named only gtk3/xdotool/pipewire/...: on a dev box everything else
# happened to be installed, but on a clean Arch the client died at once ("libpulse-simple.so.0:
# cannot open shared object file"; also libvpx, aom, libyuv, opus, libsodium, gstreamer,
# openssl missing). The list below is every library the ELFs link (NEEDED -> owning package)
# plus the ones they dlopen() at run time (X input/cursor, xkbcommon-x11, Wayland, PipeWire
# capture, EGL for Flutter).
#
# Codec libraries change their soname with upstream releases (libvpx.so.9 -> .12 ...).
# Arch replaces them in place on `pacman -Syu`, which would leave a client that no longer
# starts. So those are pinned by soname (libvpx.so=12-64): pacman then refuses an upgrade
# that would break TBFDesk and names the reason, instead of breaking it silently. The pin is
# read from the ELFs at build time, so a rebuild against a newer libvpx moves it along.
# (Seen 2026-11-11: Arch moved `openssl` to 4.x / libssl.so.4; libssl.so.3 is now in `openssl-3`,
# which the libssl.so=3-64 pin pulls in, while CachyOS still ships openssl 3.6.)
# Not bundled as in the .deb: this host's codec libs come from the CachyOS x86-64-v3 repos
# and would make the package v3-only.
ARCH_DEPENDS_COMMON="gtk3 glib2 gdk-pixbuf2 cairo pango libx11 libxcb libxfixes libxtst libxi
  libxcursor libxkbcommon libxkbcommon-x11 xdotool wayland dbus pam libpulse gstreamer
  gst-plugins-base-libs gst-plugin-pipewire pipewire libyuv libjpeg-turbo libdrm libva
  systemd-libs"
ARCH_DEPENDS_FLUTTER="at-spi2-core fontconfig harfbuzz libepoxy libglvnd"
# sonames pinned with their major version (Arch's lib provides: libvpx.so=12-64)
ARCH_PINNED_SONAMES="libvpx libaom libopus libsodium libssl libcrypto"

arch_depends() {  # $1 sciter|flutter, $2... ELF files
  local ui="$1"; shift
  local list="$ARCH_DEPENDS_COMMON" e s n out=""
  [ "$ui" = flutter ] && list="$list $ARCH_DEPENDS_FLUTTER"
  list=$(echo $list)   # one line: the ownership check below matches " name "
  for e in $list; do out="$out '$e'"; done
  # collect first: `objdump | grep -m1` under pipefail fails when grep stops early (SIGPIPE)
  local needed
  needed=$(for e in "$@"; do objdump -p "$e" | awk '/NEEDED/ {print $2}'; done | sort -u)
  for n in $ARCH_PINNED_SONAMES; do
    s=$(grep -E "^$n\.so\.[0-9]+$" <<<"$needed" | sort -V | tail -1)
    [ -n "$s" ] || { echo "arch_depends: no $n.so.N in the ELFs" >&2; return 1; }
    out="$out '$n.so=${s##*.so.}-64'"
  done
  # warn about a linked library whose package is not listed (ownership as on the build host)
  local owners
  owners=$(while read -r s; do [ -e "/usr/lib/$s" ] && pacman -Qoq "/usr/lib/$s" 2>/dev/null; done <<<"$needed" | sort -u)
  for e in $owners; do
    case " $list aom libvpx opus libsodium openssl openssl-3 glibc libgcc libstdc++ gcc-libs zlib zlib-ng-compat util-linux-libs " in
      *" $e "*) ;; *) echo "WARN arch_depends: links a library of '$e', which is not in depends" >&2 ;;
    esac
  done
  echo "$out"
}

# pacman install script: enable + start the service like the .deb's postinst does (until
# 1.4.20-1 the Arch packages installed rustdesk.service but never enabled it, so a fresh
# Arch machine was not reachable until someone ran systemctl by hand). Switching UI removes
# the other package first (its pre_remove stops the service), then post_install starts it.
arch_write_install() {  # $1 = output file
  cat > "$1" <<'INST'
_tbf_start() {
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable rustdesk.service 2>/dev/null || true
  systemctl restart rustdesk.service 2>/dev/null || true
}
post_install() { _tbf_start; }
post_upgrade() { _tbf_start; }
pre_remove() { systemctl disable --now rustdesk.service 2>/dev/null || true; }
INST
}

#!/usr/bin/env bash
# Put the video-codec libraries a TBFDesk .deb links into the package itself, so the
# package survives Ubuntu release upgrades (sourced by pkg-linux.sh / pkg-linux-flutter.sh).
#
#   deb_bundle_libs <deb root> <libdir RUNPATH for the ELF files> <ELF>...
#
# Why: these libraries change their soname between Ubuntu releases -- 24.04 has libvpx.so.9
# (package libvpx9), 26.04 has only libvpx.so.12 (libvpx12). A .deb that Depends: libvpx9
# does not install on 26.04, and after `do-release-upgrade` 24.04 -> 26.04 the old libvpx9
# is "obsolete" and gets removed -> "libvpx.so.9: cannot open shared object file". The
# copies here come from the image the .deb binaries were BUILT in (localhost/nemo-gui,
# Ubuntu 24.04), land in /usr/share/rustdesk/lib and are found through RUNPATH; everything
# else the client needs (GTK, X11, PulseAudio, GStreamer, PAM, ...) keeps the same package
# names on 24.04 and 26.04 and stays a normal Depends.
# All bundled libraries are BSD-licensed; their copyright files go to
# /usr/share/doc/<package>/bundled/.
DEB_BUILD_IMAGE="${DEB_BUILD_IMAGE:-localhost/nemo-gui}"
# soname -> Ubuntu package (for the copyright file)
DEB_BUNDLED_LIBS="libvpx.so.9:libvpx9 libaom.so.3:libaom3 libyuv.so.0:libyuv0 libjpeg.so.8:libjpeg-turbo8"

deb_bundle_libs() {  # $1 root, $2 package name, $3 RUNPATH for the ELFs, $4... ELFs
  local R="$1" PKG="$2" RP="$3"; shift 3
  local L="$R/usr/share/rustdesk/lib" D="$R/usr/share/doc/$PKG/bundled" s e list=""
  command -v patchelf >/dev/null || { echo "deb_bundle_libs: patchelf missing" >&2; return 1; }
  install -d "$L" "$D"
  for e in $DEB_BUNDLED_LIBS; do list="$list ${e%%:*}"; done
  # copy the real files (cp -L) under their soname, plus the copyright files
  podman run --rm -v "$L:/l:Z" -v "$D:/d:Z" "$DEB_BUILD_IMAGE" bash -c '
    set -e
    for e in '"$DEB_BUNDLED_LIBS"'; do
      so=${e%%:*}; pkg=${e#*:}
      p=$(ldconfig -p | awk -v l="$so" "\$1==l {print \$NF; exit}")
      [ -n "$p" ] || { echo "missing $so in the build image" >&2; exit 1; }
      cp -L "$p" "/l/$so"; chmod 644 "/l/$so"
      cp "/usr/share/doc/$pkg/copyright" "/d/$pkg.copyright"
    done' || return 1
  for s in $list; do
    patchelf --set-rpath '$ORIGIN' "$L/$s" || return 1
  done
  for e in "$@"; do
    patchelf --set-rpath "$RP" "$e" || return 1
  done
  # every bundled soname must be what the ELFs ask for (catches a soname change at build time)
  for s in $list; do
    case "$s" in libjpeg.so.8) continue ;; esac   # needed by libyuv, not by the ELFs
    for e in "$@"; do
      objdump -p "$e" | awk '/NEEDED/ {print $2}' | grep -qx "$s" \
        || echo "WARN: $(basename "$e") does not link $s (bundled anyway)" >&2
    done
  done
  echo "bundled:$list (RUNPATH $RP)"
}

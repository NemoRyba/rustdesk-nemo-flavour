#!/usr/bin/env bash
# Build the OFFLINE Ubuntu installer of a TBFDesk client .deb: one self-extracting file
#   tbfdesk[-flutter]-<v>-ubuntu<rel>-install.run
# = dist/ubuntu-offline-installer.sh + a local apt repository holding the .deb and the
# COMPLETE dependency closure of it (every package down to libc6, plus the tray indicator),
# downloaded from the Ubuntu archive in a clean ubuntu:<rel> container. The full closure,
# not just what a minimal container lacks, so that an older, never-updated Ubuntu <rel>
# also finds every version it needs without internet.
#
#   pkg-ubuntu-offline.sh <client .deb> <out dir> [ubuntu release, default 24.04]
set -euo pipefail
DEBF="$(readlink -f "${1:?client .deb}")"; OUT="$(readlink -f "${2:?out dir}")"; REL="${3:-24.04}"
HERE="$(dirname "$(readlink -f "$0")")"
PKG="$(ar p "$DEBF" control.tar.gz | tar xzO ./control | awk -F': ' '$1=="Package"{print $2}')"
VER="$(ar p "$DEBF" control.tar.gz | tar xzO ./control | awk -F': ' '$1=="Version"{print $2}')"
DEPS="$(ar p "$DEBF" control.tar.gz | tar xzO ./control | awk -F': ' '$1=="Depends"{print $2}')"
case "$PKG" in tbfdesk) UI=Sciter ;; tbfdesk-flutter) UI=Flutter ;; *) echo "not a TBFDesk client .deb: $PKG" >&2; exit 1 ;; esac
RUN="$PKG-$VER-ubuntu$REL-install.run"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo" "$OUT"
cp "$DEBF" "$WORK/repo/"
NAMES="$(echo "$DEPS" | tr ',|' '\n\n' | sed 's/(.*)//; s/^ *//; s/ *$//' | grep -v '^$' | sort -u | tr '\n' ' ') libayatana-appindicator3-1"

echo "== downloading the dependency closure of $PKG $VER from the Ubuntu $REL archive"
podman run --rm -v "$WORK/repo:/repo:Z" "docker.io/library/ubuntu:$REL" bash -c '
  set -e
  apt-get update -qq
  # every real package reachable through Depends/Pre-Depends (no Recommends); alternatives
  # and virtual names that have no package of their own are dropped
  all=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks \
          --no-replaces --no-enhances '"$NAMES"' 2>/dev/null | grep -E "^[a-z0-9]" | sort -u)
  real=$(for p in $all; do apt-cache show --no-all-versions "$p" >/dev/null 2>&1 && echo "$p"; done)
  cd /repo && apt-get download $real >/dev/null
  echo "$(ls *.deb | wc -l) packages"
  apt-get install -y -qq dpkg-dev >/dev/null 2>&1
  dpkg-scanpackages --multiversion . /dev/null 2>/dev/null > Packages
  gzip -9k Packages
  sha256sum *.deb Packages Packages.gz > SHA256SUMS'
du -sh "$WORK/repo"

sed -e "s/@VER@/$VER/g; s/@UI@/$UI/g; s/@PKG@/$PKG/g; s/@REL@/$REL/g; s/@RUN@/$RUN/g; s/@DEB@/$(basename "$DEBF")/g" \
  "$HERE/ubuntu-offline-installer.sh" > "$OUT/$RUN"
( cd "$WORK" && tar --owner=0 --group=0 -cf - repo ) >> "$OUT/$RUN"
chmod 755 "$OUT/$RUN"
echo "built $OUT/$RUN ($(du -h "$OUT/$RUN" | cut -f1))"
( cd "$OUT" && sha256sum "$RUN" | tee "$RUN.sha256" )

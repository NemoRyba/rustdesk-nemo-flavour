#!/usr/bin/env bash
# TBFDesk client @VER@ (@UI@ UI) -- installer for Ubuntu @REL@, works WITHOUT internet.
# One self-contained file: this script + the TBFDesk .deb + every package it needs (the
# complete dependency closure, downloaded from the Ubuntu @REL@ archive when the installer
# was built; dist/pkg-ubuntu-offline.sh).
#
#   bash ./@RUN@              dialog (GUI on a desktop, text UI in a terminal / over SSH)
#   bash ./@RUN@ --yes        unattended
#   bash ./@RUN@ --online     use the machine's own apt sources instead of the bundled ones
#   bash ./@RUN@ --extract DIR    only unpack (the .deb + the local package repository)
#
# Installing over an existing TBFDesk -- Sciter or Flutter, older or newer -- keeps the ID,
# the keys, the server settings and the managed policy (they live in ~/.config/tbfdesk and
# /root/.config/tbfdesk, which a package install never touches). The other UI's package is
# replaced (one TBFDesk per machine).
# The bundled packages are only used for what is missing: apt never downgrades a library
# the machine already has, and the machine's apt sources are not changed.
set -uo pipefail
VER="@VER@"; UI="@UI@"; PKG="@PKG@"; REL="@REL@"; DEB="@DEB@"
APP="TBFDesk $VER ($UI)"
MODE=install; YES=""; ONLINE=""
ARGS=("$@")   # the loop below shifts; the root re-exec needs them all
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --online) ONLINE=1 ;;
    --extract) MODE=extract; XDIR="${2:-./tbfdesk-$VER-ubuntu$REL}"; shift ;;
    --text) FORCE_TEXT=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  esac
  shift
done

# ---- root -------------------------------------------------------------------------------
if [ "$(id -u)" != 0 ] && [ "$MODE" != extract ]; then
  if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ ! -t 0 ]; then
    exec pkexec env DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
      XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" bash "$(readlink -f "$0")" "${ARGS[@]}"
  fi
  exec sudo -E bash "$(readlink -f "$0")" "${ARGS[@]}"
fi

# ---- unpack -----------------------------------------------------------------------------
WORK="$(mktemp -d /tmp/tbfdesk-install.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"   # apt's _apt download user must be able to read the local repository
LINE=$(awk '/^__TBFDESK_PAYLOAD_BELOW__$/ { print NR + 1; exit 0; }' "$0")
tail -n +"$LINE" "$0" | tar x -C "$WORK" || { echo "$APP: the installer file is damaged" >&2; exit 1; }
( cd "$WORK/repo" && sha256sum -c --quiet SHA256SUMS ) || { echo "$APP: the installer file is damaged (checksums)" >&2; exit 1; }
if [ "$MODE" = extract ]; then
  mkdir -p "$XDIR" && cp -a "$WORK/repo" "$XDIR/" && echo "unpacked to $XDIR/repo ($DEB + $(ls "$WORK/repo"/*.deb | wc -l) packages)"
  exit 0
fi

# ---- dialogs: zenity / kdialog on a desktop, whiptail in a terminal, plain text last -----
GUI=text
if [ -z "${FORCE_TEXT:-}" ]; then
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then GUI=zenity
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v kdialog >/dev/null 2>&1; then GUI=kdialog
  elif [ -t 0 ] && command -v whiptail >/dev/null 2>&1; then GUI=whiptail; fi
fi
[ -n "$YES" ] && GUI=none
msg() {
  case "$GUI" in
    zenity) zenity --info --title "$APP" --width=640 --text "$1" 2>/dev/null ;;
    kdialog) kdialog --title "$APP" --msgbox "$1" 2>/dev/null ;;
    whiptail) whiptail --title "$APP" --msgbox "$1" 22 78 ;;
    *) printf '\n%s\n' "$1" ;;
  esac
}
ask() {   # yes/no, default YES
  case "$GUI" in
    zenity) zenity --question --title "$APP" --width=640 --text "$1" 2>/dev/null ;;
    kdialog) kdialog --title "$APP" --yesno "$1" 2>/dev/null ;;
    whiptail) whiptail --title "$APP" --yesno "$1" 22 78 ;;
    none) return 0 ;;
    *) printf '%s [Y/n] ' "$1"; read -r r; [ "$r" != n ] && [ "$r" != N ] ;;
  esac
}

# ---- what is there ----------------------------------------------------------------------
. /etc/os-release 2>/dev/null || true
OS="${PRETTY_NAME:-unknown Linux}"
installed=""
for p in tbfdesk tbfdesk-flutter rustdesk; do
  v="$(dpkg-query -W -f='${Status} ${Version}' "$p" 2>/dev/null | awk '/install ok installed/ {print $4}')"
  [ -n "$v" ] && installed="$installed$p $v; "
done
cfg=""; for d in /root/.config/tbfdesk /home/*/.config/tbfdesk; do [ -d "$d" ] && cfg="$cfg $d"; done
NOTE=""
if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != "$REL" ]; then
  NOTE="
NOTE: this machine runs $OS; the bundled packages are for Ubuntu $REL.
The machine's own apt sources are used for anything missing (internet needed)."
  ONLINE=1
fi
command -v apt-get >/dev/null 2>&1 || { msg "$APP: this installer needs Debian/Ubuntu (apt-get)."; exit 1; }

ask "Install $APP?

This machine: $OS
Installed now: ${installed:-no TBFDesk}
Configuration kept:${cfg:- (none yet)}

ID, keys, server settings and policy are KEPT -- an install or update never touches them.
All required packages are included; no internet connection is needed.$NOTE" \
  || { echo "Cancelled -- nothing was changed."; exit 0; }

# ---- install ----------------------------------------------------------------------------
LOG="$WORK/install.log"
export DEBIAN_FRONTEND=noninteractive
progress() { if [ "$GUI" = zenity ]; then zenity --progress --pulsate --no-cancel --auto-close --title "$APP" --text "$1" 2>/dev/null; else cat >/dev/null; fi; }
rc=0
if [ -z "$ONLINE" ]; then
  # apt with ONLY the bundled repository as source, own lists and no package cache, so the
  # machine's apt configuration and state stay exactly as they were
  mkdir -p "$WORK/lists/partial" "$WORK/parts"
  echo "deb [trusted=yes] file:$WORK/repo ./" > "$WORK/sources.list"
  APTO=(-o Dir::Etc::SourceList="$WORK/sources.list" -o Dir::Etc::SourceParts="$WORK/parts"
        -o Dir::State::Lists="$WORK/lists" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=
        -o APT::Get::List-Cleanup=0)
  { apt-get "${APTO[@]}" update && \
    apt-get "${APTO[@]}" install -y --no-install-recommends "$PKG" libayatana-appindicator3-1; } \
    > "$LOG" 2>&1 < /dev/null | progress "Installing TBFDesk and the packages it needs ..."
  rc=${PIPESTATUS[0]}
  [ $rc = 0 ] || grep -E '^E:|unmet|Depends:' "$LOG" | head -12 > "$WORK/err"
fi
if [ -n "$ONLINE" ] || [ $rc != 0 ]; then
  # different release, or the bundled set did not fit this machine: the .deb through the
  # machine's own sources (internet)
  { apt-get update; apt-get install -y "$WORK/repo/$DEB"; } >> "$LOG" 2>&1 < /dev/null | progress "Installing TBFDesk (online) ..."
  rc=${PIPESTATUS[0]}
fi

# ---- check ------------------------------------------------------------------------------
now="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)"
# (plugins find libflutter_linux_gtk.so through the executable's RUNPATH: give ldd the dir)
missing="$(for f in /usr/share/rustdesk/rustdesk /usr/share/rustdesk/lib/*.so*; do [ -f "$f" ] && LD_LIBRARY_PATH=/usr/share/rustdesk/lib ldd "$f" 2>/dev/null | grep 'not found'; done | sort -u)"
svc="not checked (no systemd)"
if [ -d /run/systemd/system ]; then
  for i in $(seq 10); do systemctl is-active --quiet rustdesk && break; sleep 1; done
  systemctl is-active --quiet rustdesk && svc="running" || svc="NOT running (journalctl -u rustdesk)"
fi
if [ $rc = 0 ] && [ "$now" = "$VER" ] && [ -z "$missing" ]; then
  msg "$APP is installed.

Service: $svc
Configuration kept:${cfg:- (new installation)}
Start it from the applications menu (TBFDesk) or with: rustdesk"
  exit 0
fi
msg "$APP: installation FAILED (exit $rc, installed version: ${now:-none}).
$( [ -n "$missing" ] && echo "Missing libraries: $missing")
$(cat "$WORK/err" 2>/dev/null)
$(tail -6 "$LOG")

Full log: /var/log/tbfdesk-install.log"
cp "$LOG" /var/log/tbfdesk-install.log 2>/dev/null
exit 1
__TBFDESK_PAYLOAD_BELOW__

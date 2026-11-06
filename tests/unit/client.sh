#!/usr/bin/env bash
# unit-client: the client's cargo unit tests (stage of tests/run-all.sh).
#
# Two upstream tests depend on the machine's session, not on the code. They are handled
# here, in the runner -- the upstream tests stay untouched:
#
#   platform::tests::test_get_cursor_pos
#       asks the X display where the pointer is (the service's pointer-position lookup).
#       Without a display (a terminal / SSH session) it cannot pass, so it gets a throwaway
#       Xvfb and still tests something. Skipped only if Xvfb is missing.
#   platform::linux::desktop::tests::test_desktop_env
#       asks logind who is logged in at the graphical seat (seat0) -- the service's "whose
#       desktop do I share" lookup -- and compares that user's home with $HOME. When seat0
#       belongs to someone else (e.g. the SDDM/GDM login screen while you work remotely) it
#       cannot pass: skipped, with the reason printed.
#
# Every skip is printed as "SKIP <test>: <reason>" and kept in the log; nothing is silent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
cd "$TBF_CLIENT" || exit 1
source "$HERE/../lib/client-env.sh"
mkdir -p "$TBF_OUT"
LOG="$TBF_OUT/unit-client.log"
: > "$LOG"
SKIPS=()
skip() { SKIPS+=(--skip "$1"); echo "SKIP $1: $2" | tee -a "$LOG"; }

# --- pointer test: give it a display ----------------------------------------------------
XVFB_PID=""
cleanup() { [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null; }
trap cleanup EXIT
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  if command -v Xvfb >/dev/null 2>&1; then
    for n in $(seq 90 120); do
      [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X$n-lock" ] || break
    done
    Xvfb ":$n" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
    XVFB_PID=$!
    for _ in $(seq 20); do [ -e "/tmp/.X11-unix/X$n" ] && break; sleep 0.2; done
    export DISPLAY=":$n"
    echo "note: no display in this session -- test_get_cursor_pos runs on a throwaway Xvfb $DISPLAY" | tee -a "$LOG"
  else
    skip platform::tests::test_get_cursor_pos "no display in this session and no Xvfb installed"
  fi
fi

# --- desktop-session test: only when seat0 is the user running the tests -----------------
me=$(id -un)
if [ "$me" != root ] && command -v loginctl >/dev/null 2>&1; then
  # columns: SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE
  seat0=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $3, $6; exit}')
  if [ -n "$seat0" ]; then
    set -- $seat0
    if [ "$1" != "$me" ]; then
      skip platform::linux::desktop::tests::test_desktop_env \
        "seat0 belongs to '$1' (${2:-session}), not to '$me' -- nobody of this account is logged in at the graphical screen"
    fi
  fi
fi

cargo test --release --features "$TBF_CLIENT_FEATURES" --lib -- "${SKIPS[@]}" 2>&1 \
  | tee -a "$LOG" | grep -E '^test result|FAILED|panicked'
exit "${PIPESTATUS[0]}"

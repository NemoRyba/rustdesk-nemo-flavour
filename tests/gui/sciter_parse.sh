#!/usr/bin/env bash
# Loads the EXACT main-window page the inline release build embeds (res/inline-sciter.py
# output + the runtime common.css/common.tis substitution + BOM) into real libsciter via the
# Linux client on Xvfb, and checks:
#   1. it parses with ZERO script errors           (1.4.16: "Bad parse code" -> dead "..." menu,
#                                                     no status polling, "Generating ID" forever)
#   2. negative control: the 1.4.16 single-block page DOES fail, and the error lands in the
#      client LOG FILE                              (logging fix: script errors used to vanish)
#   3. a debug run (RUST_LOG) mirrors the log to stderr  (live log in the launching shell)
# Needs: Xvfb, openbox, libsciter-gtk.so, a built Linux client (target/release/rustdesk).
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
BIN="$TBF_CLIENT/target/release/rustdesk"
[ -x "$BIN" ] || { bad "no Linux client binary at $BIN (run the build stage)"; exit 1; }
T=$(mktemp -d "$TBF_OUT/sciter-parse.XXXX"); fail=0
DISP="${TBF_XDISPLAY:-:88}"

ensure_display() {
  pgrep -f "Xvfb $DISP " >/dev/null || { Xvfb "$DISP" -screen 0 1400x900x24 -nolisten tcp >"$T/xvfb.log" 2>&1 & sleep 2; }
  DISPLAY="$DISP" pgrep -x openbox >/dev/null || { DISPLAY="$DISP" openbox >"$T/openbox.log" 2>&1 & sleep 1; }
}

# <index.html to use> <outdir>: the real generator, then the runtime substitution, + BOM.
make_page() {
  local w="$2/gen"; mkdir -p "$w/res" "$w/src/ui" "$2/page/src/ui"
  cp "$TBF_CLIENT/res/inline-sciter.py" "$w/res/"
  cp "$TBF_CLIENT"/src/ui/*.{tis,html,css} "$w/src/ui/"
  cp "$1" "$w/src/ui/index.html"
  (cd "$w" && python3 res/inline-sciter.py) || return 1
  python3 - "$w/src/ui/inline.rs" "$2/page/src/ui/index.html" <<'PY'
import re, sys, codecs
rs = open(sys.argv[1], encoding="ascii").read()
def lit(n):
    m = re.search(r'const %s: &\[u8; \d+\] = b"(.*?)";\n' % n, rs, re.S)
    return codecs.escape_decode(m.group(1).encode("latin-1"))[0].decode("utf-8")
page = lit("_INDEX").replace("@import url(common.css);", lit("_COMMON_CSS")).replace('include "common.tis";', lit("_COMMON_TIS"))
open(sys.argv[2], "w", encoding="utf-8").write("﻿" + page)
PY
}

# A HOME whose config reaches the main view (well-formed device key) but no server (TEST-NET).
make_home() {
  mkdir -p "$1/.config/tbfdesk"   # Linux config dir is the lowercased app name
  python3 - "$1/.config/tbfdesk/TBFDesk2.toml" <<'PY'
import base64, os, sys
key = base64.b64encode(os.urandom(64)).decode()
open(sys.argv[1], "w").write(f"""rendezvous_server = '192.0.2.1:21116'
[options]
custom-rendezvous-server = '192.0.2.1'
nemo-device-key = '{key}'
""")
PY
}

kill_ours() {  # every client process running with HOME=$1
  for p in /proc/[0-9]*; do
    [ "$(readlink "$p/exe" 2>/dev/null)" = "$BIN" ] || continue
    tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -qx "HOME=$1" && kill -9 "${p#/proc/}" 2>/dev/null
  done
}

run_page() {  # <pagedir> <home> <out-prefix> [extra env...]
  local page=$1 home=$2 out=$3; shift 3
  ( cd "$page" && exec env -u WAYLAND_DISPLAY HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      XDG_RUNTIME_DIR="$home/run" DISPLAY="$DISP" GDK_BACKEND=x11 XDG_SESSION_TYPE=x11 "$@" \
      stdbuf -o0 -e0 "$BIN" </dev/null >"$out.stdout" 2>"$out.stderr" ) &
  disown $!   # we kill it ourselves below; keep bash from reporting the job
  sleep "${TBF_PARSE_WAIT:-8}"
  kill_ours "$home"; sleep 1
}

ensure_display

# 1. the page this build embeds
make_page "$TBF_CLIENT/src/ui/index.html" "$T/cur" || { bad "generator failed"; exit 1; }
mkdir -p "$T/home1/run"; chmod 700 "$T/home1/run"; make_home "$T/home1"
run_page "$T/cur/page" "$T/home1" "$T/cur"
n=$(grep -c 'ERROR:TIS' "$T/cur.stderr")
if [ "$(grep -c 'INFO:TIS' "$T/cur.stdout")" -lt 1 ]; then
  bad "the page did not run at all (no TIS output) -- see $T/cur.stderr"; fail=1
elif [ "$n" -eq 0 ]; then ok "embedded main-window page parses with 0 script errors"
else bad "embedded page has $n script error(s): $(grep -m1 -A1 'ERROR:TIS' "$T/cur.stderr" | tr '\n' ' ')"; fail=1; fi

# 2. negative control + logging: the 1.4.16 single-block page
git -C "$TBF_CLIENT" show 7c1dd6426:src/ui/index.html > "$T/old-index.html"
make_page "$T/old-index.html" "$T/old" || { bad "generator failed (old page)"; exit 1; }
mkdir -p "$T/home2/run"; chmod 700 "$T/home2/run"; make_home "$T/home2"
run_page "$T/old/page" "$T/home2" "$T/old"
if grep -q 'Bad parse code' "$T/old.stderr"; then
  ok "negative control: the 1.4.16 single-block page fails with 'Bad parse code'"
  logf=$(find "$T/home2/.local/share/logs" -name '*.log' 2>/dev/null | xargs grep -l 'sciter TIS' 2>/dev/null | head -1)
  if [ -n "$logf" ] && grep -q 'sciter TIS: Error: Bad parse code' "$logf"; then
    ok "the script error is in the client log file ($(basename "$(dirname "$logf")")/$(basename "$logf"))"
  else bad "the script error did NOT reach the log file (logging regression)"; fail=1; fi
else
  bad "negative control did not fail -- this check can no longer detect the per-block limit"; fail=1
fi

# 3. debug run mirrors the log to stderr
mkdir -p "$T/home3/run"; chmod 700 "$T/home3/run"; make_home "$T/home3"
run_page "$T/cur/page" "$T/home3" "$T/dbg" RUST_LOG=debug
if grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2} .*sciter TIS' "$T/dbg.stderr"; then
  ok "RUST_LOG run mirrors the log (incl. script output) to stderr"
else bad "RUST_LOG run did not mirror the log to stderr"; fail=1; fi

[ $fail -eq 0 ] && rm -rf "$T" || say "artifacts kept in $T"
exit $fail

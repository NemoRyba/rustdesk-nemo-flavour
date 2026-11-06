#!/usr/bin/env bash
# session-linux: a remote-control session as a user has it -- TWO local monitors, a remote
# computer with TWO displays -- with BOTH viewers (Sciter and Flutter), host-only lab:
#   1. display modes single / all / span / windows: the remote cursor shape on both
#      monitors (9 cursor kinds), plus screen / cursor / input delay, fps, CPU, memory
#   2. keyboard and mouse: text, special keys, 12 shortcuts, German layout with AltGr and
#      umlauts, left/middle/right/double click, 4 wheel directions, drag
#   3. the cursor while a button is held (drag / resize) and after release
#   4. console session (command line only): a remote shell answers; refused when the
#      remote has "Enable terminal" off
# Lab scripts: vm/scripts/cursor-lab, vm/scripts/console-lab (LAB.md "Session tests").
# Known, accepted results are listed in tests/README.md (Sciter on Linux: horizontal wheel).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/../lib/common.sh"
VM=${TBF_VM:-/projects/rustdesk/vm}; CL=$VM/scripts/cursor-lab
WT=${TBF_SESSION_SCITER_WT:-$VM/build/client-nemo-tdd}
FB=${TBF_FLUTTER_BUNDLE:-$TBF_CLIENT/flutter/build/linux/x64/release/bundle}
[ -x "$WT/target/release/rustdesk" ] || { echo "SKIP: no Sciter lab build in $WT"; exit 2; }
command -v Xvnc >/dev/null || { echo "SKIP: Xvnc (tigervnc) missing"; exit 2; }
LOG=$TBF_OUT/session-linux; mkdir -p $LOG
fails=0
run() { local name=$1; shift; echo "-- $name"; "$@" < /dev/null > $LOG/$name.log 2>&1
  grep -h "^RESULT\|FAIL" $LOG/$name.log | sed 's/^/   /'; }
ui_env() { if [ "$1" = flutter ]; then echo "CTL_BIN=$FB/rustdesk CTL_DIR=$FB"; fi; }
uis=(sciter); [ -x "$FB/rustdesk" ] && uis+=(flutter) || echo "note: no Flutter bundle at $FB -- Sciter only"
for ui in "${uis[@]}"; do
  e=$(ui_env $ui)
  run modes-$ui env $e TAG=suite-$ui bash $CL/multidisplay-cursor-test.sh $WT
  for lay in us de; do run input-$ui-$lay env $e LAYOUT=$lay TAG=suite-$ui-$lay bash $CL/input-test.sh; done
  run hold-$ui env $e TAG=suite-$ui bash $CL/hold-test-linux.sh
done
run console bash $VM/scripts/console-lab/console-test.sh
# verdicts: each log's RESULT line must report no failure ("n/m" for the display modes,
# "n failure(s)" elsewhere). Accepted: Sciter on Linux turns a horizontal wheel into a
# vertical one (libsciter-gtk reports it so) -- its input tests may fail exactly those 2.
for f in $LOG/*.log; do
  r=$(grep -h "^RESULT" "$f" | tail -1)
  other=$(grep -h " FAIL " "$f" | grep -v -E "^wheel (left|right) " || true)
  case "$f" in
    *input-sciter*) ok=$([ -n "$r" ] && [ -z "$other" ] && echo y);;
    *) ok=$([ -n "$r" ] && ! echo "$r" | grep -q -E ':[1-9][0-9]*/|[1-9][0-9]* failure' && echo y);;
  esac
  [ "$ok" = y ] || { echo "FAIL $(basename $f .log): ${r:-no RESULT line}"; fails=$((fails + 1)); }
done
echo "session-linux: $fails failing check(s); logs $LOG"
exit $(( fails > 0 ))

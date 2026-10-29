#!/usr/bin/env bash
# Real GUI test of the Linux client against the LAB server, driven by clicks + OCR:
#   1. the main window registers: shows its ID / "Registriert", never stuck on "Generating"
#      (1.4.16: the status polling never started)
#   2. the "..." menu opens, and Settings opens from it            (1.4.16: dead menu)
#   3. script output reaches the client log file, no script error  (logging fix)
#   4. #43: the server receives this client's applied-policy report (row "ui" in sync)
# Exit: 0 pass, 1 fail, 2 skipped (no lab server / tools).
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
OCR="python3 $TBF_TESTS/lib/ocr.py"
BIN="$TBF_CLIENT/target/release/rustdesk"
ID="${TBF_LINUX_TEST_ID:-777000111}"
LABEL="test-suite linux"
SRV="${TBF_LAB_HOST_IP:-10.66.0.1}"     # a ROUTABLE host address (hbbr treats loopback as its command port)
DISP="${TBF_XDISPLAY_GUI:-:89}"
lab_hbbs_pid >/dev/null || { say "SKIP: no lab hbbs running"; exit 2; }
for t in Xvfb openbox xdotool import tesseract; do command -v $t >/dev/null || { say "SKIP: $t missing"; exit 2; }; done
[ -x "$BIN" ] || { bad "no Linux client binary at $BIN (run the build stage)"; exit 1; }
T=$(mktemp -d "$TBF_OUT/linux-gui.XXXX"); fail=0; H="$T/home"

pgrep -f "Xvfb $DISP " >/dev/null || { Xvfb "$DISP" -screen 0 1400x900x24 -nolisten tcp >"$T/xvfb.log" 2>&1 & disown; sleep 2; }
# A window manager on THIS display (pgrep -x openbox would match one serving another display).
WMPID="$TBF_OUT/openbox${DISP#:}.pid"
if ! { [ -f "$WMPID" ] && kill -0 "$(cat "$WMPID")" 2>/dev/null; }; then
  DISPLAY="$DISP" openbox --sm-disable >"$T/openbox.log" 2>&1 & echo $! > "$WMPID"; disown; sleep 1
fi

kill_client() {
  for p in /proc/[0-9]*; do
    [ "$(readlink "$p/exe" 2>/dev/null)" = "$BIN" ] || continue
    tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -qx "HOME=$H" && kill -9 "${p#/proc/}" 2>/dev/null
  done
}
cleanup() {
  kill_client
  if [ "${TBF_KEEP:-0}" != 1 ]; then
    admin_api POST "/nemo/api/peers/$ID/delete" '{}' >/dev/null 2>&1
  fi
}
trap cleanup EXIT

# identity + a device key bound to it, issued by the lab server
mkdir -p "$H/.config/tbfdesk" "$H/run"; chmod 700 "$H/run"
printf "id = '%s'\n" "$ID" > "$H/.config/tbfdesk/TBFDesk.toml"
issue_device_key "$ID" "$LABEL" "$SRV" "$SRV:21117" "https://$SRV:31120" > "$T/key.json"
client_config_from_key "$T/key.json" > "$H/.config/tbfdesk/TBFDesk2.toml" 2>"$T/cfg.err" \
  || { bad "could not issue a lab device key: $(head -c 200 "$T/key.json")"; exit 1; }

# the non-inline Linux build loads src/ui from its working directory
( cd "$TBF_CLIENT" && exec env -u WAYLAND_DISPLAY HOME="$H" XDG_CONFIG_HOME="$H/.config" \
    XDG_RUNTIME_DIR="$H/run" DISPLAY="$DISP" GDK_BACKEND=x11 XDG_SESSION_TYPE=x11 \
    "$BIN" </dev/null >"$T/client.out" 2>&1 ) & disown

W=""
for i in $(seq 1 40); do W=$(DISPLAY="$DISP" xdotool search --name '^TBFDesk$' 2>/dev/null | head -1); [ -n "$W" ] && break; sleep 1; done
[ -n "$W" ] || { bad "the main window never appeared (see $T/client.out)"; exit 1; }
DISPLAY="$DISP" xdotool windowactivate "$W" 2>/dev/null
eval "$(DISPLAY="$DISP" xdotool getwindowgeometry --shell "$W")"   # X Y WIDTH HEIGHT
shot() { import -display "$DISP" -window root "$1" 2>/dev/null; }
# Hover first: Sciter only takes the click once the element under the pointer has seen it.
click() { DISPLAY="$DISP" xdotool mousemove "$1" "$2"; sleep 0.5; DISPLAY="$DISP" xdotool click 1; }

# 1. registration
reg=""
for i in $(seq 1 30); do shot "$T/main.png"; $OCR has "$T/main.png" 'Registriert|Registered' && { reg=1; break; }; sleep 3; done
if [ -n "$reg" ]; then ok "main window registered with the lab server (ID shown, not stuck on 'Generating')"
else bad "main window never registered -- see $T/main.png"; fail=1; fi
$OCR has "$T/main.png" 'Wird generiert|Generating' && { bad "main window still shows 'Generating ...'"; fail=1; }

# 2. the "..." menu -> Settings
if $OCR has "$T/main.png" 'Einstellungen|Settings' --region "$X,$Y,500,300"; then
  bad "menu text already on screen before clicking -- cannot prove the click"; fail=1
else
  menu=""
  for off in "161 40" "161 36" "165 40" "157 40" "161 44"; do
    set -- $off; click $((X + $1)) $((Y + $2)); sleep 1.2; shot "$T/menu.png"
    menu=$($OCR find "$T/menu.png" 'Einstellungen|Settings' --region "$X,$Y,600,320") && break
    DISPLAY="$DISP" xdotool key Escape; sleep 0.5
  done
  if [ -n "$menu" ]; then
    ok "the '...' menu opens ($(echo "$menu" | cut -d' ' -f3-))"
    set -- $menu; click "$1" "$2"; sleep 2; shot "$T/settings.png"
    if $OCR has "$T/settings.png" 'Allgemein|General'; then ok "Settings opens from the menu"
    else bad "Settings did not open -- see $T/settings.png"; fail=1; fi
  else bad "the '...' menu did not open -- see $T/menu.png"; fail=1; fi
fi

# 3. log file: script output present, no script error
logf=$(ls -t "$H"/.local/share/logs/TBFDesk/*.log 2>/dev/null | head -1)
if [ -n "$logf" ] && grep -q 'sciter TIS' "$logf"; then
  if grep -q 'Bad parse code\|sciter TIS: Error' "$logf"; then bad "script error in the log: $(grep -m1 'sciter TIS: Error' "$logf")"; fail=1
  else ok "script output is in the log file, no script error"; fi
else bad "no script output in the log file ($logf)"; fail=1; fi

# 4. #43: the server got this client's report and it matches what was handed over
st=$(wait_for_value in_sync 120 peer_field "$ID" policy_applied.ui.state)
if [ "$st" = in_sync ]; then ok "#43: server shows the policy this client applied (ui: in_sync)"
else bad "#43: applied-policy state for $ID is '$st', expected in_sync"; fail=1; fi

[ $fail -eq 0 ] && { rm -rf "$T"; exit 0; } || { say "artifacts kept in $T"; exit 1; }

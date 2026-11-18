#!/usr/bin/env bash
# Real GUI test of the WINDOWS client on the Win11 test VM against the LAB server:
#   0. installs the installer under test OVER whatever is installed (the upgrade path)
#   2. a debug run with stderr redirected writes the mirrored log into the file
#   3. the main window registers: ID / "Registriert", never "Wird generiert"   (1.4.16 bug)
#   4. the "..." menu opens, and Settings opens from it                         (1.4.16 bug)
#   5. the client log carries script output and no script error                 (logging fix)
#   6. #43: the server shows the policy this machine applied (service row in sync)
#   7. a debug run started from a console streams its log INTO that console (AttachConsole)
# Usage: windows_client.sh [C:\path\to\installer.exe]   (default: C:\src\dist\tbfdesk-<ver>-x64-install.exe)
# Exit: 0 pass, 1 fail, 2 skipped (VM or lab server not up).
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
OCR="python3 $TBF_TESTS/lib/ocr.py"
VER="${TBF_WIN_VERSION:-$(grep -m1 '^version' "$TBF_CLIENT/Cargo.toml" | cut -d'"' -f2)}"
INST="${1:-C:\\src\\dist\\tbfdesk-$VER-x64-install.exe}"
LABEL="test-suite vm"
vm_ready || { say "SKIP: Windows VM not up (vmctl.sh start)"; exit 2; }
lab_hbbs_pid >/dev/null || { say "SKIP: no lab hbbs running"; exit 2; }
T=$(mktemp -d "$TBF_OUT/win-gui.XXXX"); fail=0
vps()  { vmctl ps "$1" 2>&1 | tr -d '\r'; }
vin()  { vmctl input "$@" 2>&1 | tr -d '\r'; }
shot() { "$TBF_VM/scripts/vmshot.sh" "$1" >/dev/null 2>&1; }
trap 'rm -f "$T/key.json" "$T/TBFDesk2.toml"; vps "& C:\src\tbf-test\stop-ui.ps1" >/dev/null' EXIT

vps 'New-Item -ItemType Directory -Force C:\src\tbf-test | Out-Null; "ok"' >/dev/null
for f in "$TBF_TESTS"/gui/win/*; do vmctl put "$f" "C:/src/tbf-test/$(basename "$f")" >/dev/null 2>&1; done

# 0. install / upgrade
out=$(vps "& C:\src\tbf-test\install.ps1 -Installer '$INST'")
got=$(echo "$out" | sed -n 's/^version=//p')
if [ "$got" = "$VER" ]; then ok "installed $VER over the existing install ($(echo "$out" | sed -n 's/^seconds=//p') s, service $(echo "$out" | sed -n 's/^service=//p'))"
else bad "install of $INST gave version '$got', expected $VER: $out"; exit 1; fi

# config: a lab device key bound to this machine's ID
VMID=$(vps '& "C:\Program Files\TBFDesk\tbfdesk.exe" --get-id | Out-String' | grep -E '^[0-9]{6,}$' | tail -1)
[ -n "$VMID" ] || { bad "could not read the VM's TBFDesk ID"; exit 1; }
issue_device_key "$VMID" "$LABEL" 10.0.2.2 10.0.2.2:21117 https://10.0.2.2:31120 > "$T/key.json"
client_config_from_key "$T/key.json" > "$T/TBFDesk2.toml" || { bad "could not issue a lab device key"; exit 1; }
vmctl put "$T/TBFDesk2.toml" 'C:/src/tbf-test/TBFDesk2.toml' >/dev/null 2>&1
vps '& C:\src\tbf-test\apply-config.ps1 -Toml C:\src\tbf-test\TBFDesk2.toml' | grep -q 'service=Running' \
  || { bad "service did not come back after applying the lab config"; exit 1; }
say "VM id $VMID provisioned against the lab server"

# input agent (in-guest clicker), minimized so a stray click cannot pause it
case "$(vin CURSOR)" in *cursor*) ;; *)
  vmctl gui powershell.exe -ExecutionPolicy Bypass -WindowStyle Minimized -File 'C:\tbf-new\inputagent.ps1' >/dev/null 2>&1; sleep 6;;
esac

# 2. stderr mirroring (and the UI instance for the GUI checks)
vps '& C:\src\tbf-test\stop-ui.ps1' >/dev/null
vmctl gui 'C:\src\tbf-test\run-ui-debug.cmd' >/dev/null 2>&1; sleep 15
n=$(vps '(Select-String C:\src\tbf-test\ui-err.txt -Pattern "^\[20\d\d-" -EA SilentlyContinue | Measure-Object).Count' | tail -1)
if [ "${n:-0}" -gt 0 ] 2>/dev/null; then ok "RUST_LOG run mirrors the log to redirected stderr ($n lines)"
else bad "no mirrored log lines in the redirected stderr"; fail=1; fi

# 3. registration (nothing else of ours may be on screen: a console in front swallows clicks)
rect=$(vin "FOCUS tbfdesk" | sed -n 's/.*rect=\([0-9-]*\),\([0-9-]*\),.*/\1 \2/p')
[ -n "$rect" ] || { bad "TBFDesk window not found"; exit 1; }
set -- $rect; WX=$1; WY=$2; sleep 1
reg=""
for i in $(seq 1 20); do shot "$T/main.png"; $OCR has "$T/main.png" 'Registriert|Registered' && { reg=1; break; }; sleep 3; done
if [ -n "$reg" ]; then ok "main window registered (ID shown, not stuck on 'Wird generiert')"
else bad "main window never registered -- see $T/main.png"; fail=1; fi
$OCR has "$T/main.png" 'Wird generiert|Generating' && { bad "main window still shows 'Wird generiert ...'"; fail=1; }
build=$($OCR find "$T/main.png" 'Build' --region "$WX,$((WY + 560)),220,60" | cut -d' ' -f3-)
[ -n "$build" ] && say "running: $build"

# 4. the "..." menu -> Settings
if $OCR has "$T/main.png" 'Einstellungen|Settings' --region "$WX,$WY,600,320"; then
  bad "menu text already on screen before clicking -- cannot prove the click"; fail=1
else
  menu=""
  for off in "169 71" "169 67" "173 71" "165 71" "169 75"; do
    set -- $off; vin "CLICK $((WX + $1)) $((WY + $2))" >/dev/null; sleep 1.5; shot "$T/menu.png"
    menu=$($OCR find "$T/menu.png" 'Einstellungen|Settings' --region "$WX,$WY,600,320") && break
    vin "TYPE {ESC}" >/dev/null; sleep 0.5
  done
  if [ -n "$menu" ]; then
    ok "the '...' menu opens ($(echo "$menu" | cut -d' ' -f3-))"
    set -- $menu; vin "CLICK $1 $2" >/dev/null; sleep 2; shot "$T/settings.png"
    if $OCR has "$T/settings.png" 'Allgemein|General|Berechtigungen|Permissions'; then ok "Settings opens from the menu"
    else bad "Settings did not open -- see $T/settings.png"; fail=1; fi
    vin "TYPE {ESC}" >/dev/null
  else bad "the '...' menu did not open -- see $T/menu.png"; fail=1; fi
fi

# 5. client log: script output present, no script error
log=$(vps '$l = Get-ChildItem C:\Users\tbf\AppData\Roaming\TBFDesk\log\tbfdesk_rCURRENT.log -EA SilentlyContinue; if ($l) { "tis=" + (Select-String $l.FullName -Pattern "sciter TIS" | Measure-Object).Count; "err=" + (Select-String $l.FullName -Pattern "Bad parse code|sciter TIS: Error" | Measure-Object).Count } else { "nolog" }')
tis=$(echo "$log" | sed -n 's/^tis=//p'); err=$(echo "$log" | sed -n 's/^err=//p')
if [ "${tis:-0}" -gt 0 ] 2>/dev/null && [ "${err:-1}" = 0 ]; then ok "client log carries script output ($tis lines), no script error"
else bad "client log: script lines=${tis:-?} errors=${err:-?} ($log)"; fail=1; fi

# 6. #43
st=$(wait_for_value in_sync 150 peer_field "$VMID" policy_applied.service.state)
if [ "$st" = in_sync ]; then ok "#43: server shows the policy this machine applied (service: in_sync)"
else bad "#43: service applied-policy state for $VMID is '$st', expected in_sync"; fail=1; fi

# 7. live debug output in the launching console -- LAST, because the console window it opens
#    stays on top and would swallow the clicks of the GUI checks above
vps '& C:\src\tbf-test\stop-ui.ps1' >/dev/null
vmctl gui 'C:\src\tbf-test\run-console-debug.cmd' >/dev/null 2>&1; sleep 18
# close only the TBFDesk window, so the console with its streamed log is alone on screen
vps '& C:\src\tbf-test\stop-ui.ps1 -UiOnly' >/dev/null; sleep 1; shot "$T/console.png"
if $OCR has "$T/console.png" 'tls13.rs|hs.rs|connect.rs|config.rs|hwcodec.rs|server.rs|sciter TIS'; then
  ok "debug run streams its log into the launching PowerShell window"
else bad "no log lines visible in the debug console -- see $T/console.png"; fail=1; fi
say "$(vps '& C:\src\tbf-test\stop-ui.ps1')"

[ $fail -eq 0 ] && { rm -rf "$T"; exit 0; } || { say "artifacts kept in $T"; exit 1; }

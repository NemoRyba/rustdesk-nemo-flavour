#!/usr/bin/env bash
# Unattended provisioning on the Win11 VM -- no GUI is ever opened:
#   1. clean uninstall (tbfdesk-uninstall.ps1 -NoGui -Components all): a genuinely new machine,
#      including the pre-rename RustDesk config the client would otherwise import again
#   2. a bad --import-setup value exits 2 and installs NOTHING
#   3. <installer> --silent-install --import-setup <file> exits 0; the service has the server
#      + device key; the machine registers and is managed (device-key auth, #43 in sync) --
#      all confirmed AFTER this run started, so state left by an earlier run cannot pass it
#   4. the installer output never echoes the setup string / device key
#   5. re-provisioning an installed client from a PIPE: Get-Content f | TBFDesk.exe --import-setup -
#      configures the service and writes no device key into the console user's config
#   6. the user then opens the main window: no device key in any log -- the user's, the
#      service's, the installer's output; and in their (possibly roaming) profile -- which
#      today it IS, by the upstream config sync: reported as KNOWN (OPEN-TODOS #48)
# Usage: windows_provision.sh [C:\path\to\installer.exe]
# Exit: 0 pass, 1 fail, 2 skipped.
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
VER="${TBF_WIN_VERSION:-$(grep -m1 '^version' "$TBF_CLIENT/Cargo.toml" | cut -d'"' -f2)}"
INST="${1:-C:\\src\\dist\\tbfdesk-$VER-x64-install.exe}"
VMID="${TBF_VM_ID:-12513041}"     # MAC-derived, so a wiped machine gets it back
vm_ready || { say "SKIP: Windows VM not up"; exit 2; }
lab_hbbs_pid >/dev/null || { say "SKIP: no lab hbbs running"; exit 2; }
T=$(mktemp -d "$TBF_OUT/win-provision.XXXX"); fail=0
T0=$(date +%s)                    # the lab hbbs runs on this host: same clock
vps() { vmctl ps "$1" 2>&1 | tr -d '\r'; }
SETUP='C:\src\tbf-test\vm.tbfsetup'
# The device key itself only ever travels in files (never in a command line or in our output).
trap 'rm -f "$T/key.json" "$T/vm.tbfsetup" "$T/dk.txt"; vps "if (Test-Path C:\src\tbf-test\stop-ui.ps1) { & C:\src\tbf-test\stop-ui.ps1 | Out-Null }; Remove-Item C:\src\tbf-test\vm.tbfsetup, C:\src\tbf-test\dk.txt, C:\src\tbf-test\inst-out.txt -Force -EA SilentlyContinue" >/dev/null' EXIT
umask 077

vps 'New-Item -ItemType Directory -Force C:\src\tbf-test | Out-Null; "ok"' >/dev/null
vmctl put "$TBF_CLIENT/res/uninstall/tbfdesk-uninstall.ps1" 'C:/src/tbf-test/tbfdesk-uninstall.ps1' >/dev/null 2>&1

# a lab device key bound to this machine, as the dashboard hands it out: one setup string
issue_device_key "$VMID" "test-suite vm" 10.0.2.2 10.0.2.2:21117 https://10.0.2.2:31120 > "$T/key.json"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["setup_internal"]; print(s["setup_string"] if isinstance(s,dict) else s)' "$T/key.json" > "$T/vm.tbfsetup" \
  || { bad "could not issue a lab device key"; exit 1; }
python3 -c 'import json,sys,base64; s=json.load(open(sys.argv[1]))["setup_internal"]; st=s["setup_string"] if isinstance(s,dict) else s; print(json.loads(base64.b64decode(st.split(":",1)[1]))["device_key"])' "$T/key.json" > "$T/dk.txt" \
  || { bad "could not read the device key from the setup string"; exit 1; }
DK=$(cat "$T/dk.txt")
vmctl put "$T/vm.tbfsetup" 'C:/src/tbf-test/vm.tbfsetup' >/dev/null 2>&1
vmctl put "$T/dk.txt" 'C:/src/tbf-test/dk.txt' >/dev/null 2>&1
# counts the files under the console user's config (both names) that contain the device key.
# Listed first: in PowerShell 5.1 a missing -Path is a TERMINATING Select-String error, which
# -EA SilentlyContinue does not catch.
LEAK_PS='$dk = (Get-Content C:\src\tbf-test\dk.txt -Raw).Trim(); $files = @(Get-ChildItem C:\Users\tbf\AppData\Roaming\TBFDesk\config, C:\Users\tbf\AppData\Roaming\RustDesk\config -Filter *.toml* -File -EA SilentlyContinue); "files=" + $files.Count; "hits=" + @($files | Select-String -Pattern $dk -SimpleMatch -List).Count'

# 1. a genuinely new machine
vps 'Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "tbfdesk.exe" -and $_.CommandLine -notmatch "--" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; powershell -ExecutionPolicy Bypass -File C:\src\tbf-test\tbfdesk-uninstall.ps1 -Mode client -NoGui -Components all | Out-Null; "gone=" + (-not (Test-Path "C:\Program Files\TBFDesk\TBFDesk.exe"))' | grep -q 'gone=True' \
  && ok "clean uninstall: no TBFDesk on the machine" || { bad "uninstall left TBFDesk behind"; exit 1; }
left=$(vps '$left = foreach ($b in "C:\Users\tbf\AppData\Roaming", "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming", "C:\Windows\System32\config\systemprofile\AppData\Roaming") { foreach ($n in "TBFDesk", "RustDesk") { foreach ($f in "$n.toml", "${n}2.toml", "$n.toml.bak", "${n}2.toml.bak") { $p = Join-Path $b "$n\config\$f"; if (Test-Path $p) { $p } } } }; "left=" + @($left).Count; $left')
echo "$left" | grep -q '^left=0' \
  && ok "no ID / keypair / device key left in any profile (TBFDesk or pre-rename RustDesk)" \
  || { bad "the uninstall left identity files the next install would import: $(echo "$left" | tr '\n' ' ')"; exit 1; }

run_installer() {  # <args...> -> prints exit=<code> and the installer output
  local list=""; for a in "$@"; do list="$list,'$a'"; done; list=${list#,}
  # $p.Handle: without it, Windows PowerShell 5.1 loses the exit code of a process it did
  # not start with -Wait. Not -Wait itself: it waits for the tray the install spawns, too.
  vps "\$o = 'C:\src\tbf-test\inst-out.txt'; \$p = Start-Process '$INST' -ArgumentList $list -PassThru -RedirectStandardOutput \$o -WindowStyle Hidden; \$null = \$p.Handle; \$p.WaitForExit(); 'exit=' + \$p.ExitCode; Get-Content \$o -EA SilentlyContinue"
}

# 2. bad input: nothing installed
out=$(run_installer --silent-install --import-setup 'tbfdesk-setup-v1:not-a-real-string')
code=$(echo "$out" | sed -n 's/^exit=//p'); present=$(vps '"present=" + (Test-Path "C:\Program Files\TBFDesk\TBFDesk.exe")')
[ "$code" = 2 ] && echo "$present" | grep -q 'present=False' \
  && ok "a bad setup string exits 2 and installs nothing" || { bad "bad setup string: exit '$code', $present"; fail=1; }

# 3. the real thing
out=$(run_installer --silent-install --import-setup "$SETUP")
code=$(echo "$out" | sed -n 's/^exit=//p')
if [ "$code" = 0 ] && echo "$out" | grep -q 'TBFDesk service provisioned' && echo "$out" | grep -q 'device key: imported'; then
  ok "silent install + provisioning in one call: exit 0 ($(echo "$out" | grep -c '^  ') values reported)"
else bad "silent install with --import-setup: exit '$code'; output: $(echo "$out" | grep -vF "$DK" | tr '\n' '|' | head -c 400)"; fail=1; fi
# 4. never the secret
if echo "$out" | grep -qF "$DK" || echo "$out" | grep -q 'tbfdesk-setup-v1:'; then bad "installer output leaks the setup string / device key"; fail=1
else ok "installer output does not contain the setup string or the device key"; fi
svc=$(vps '$f = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\TBFDesk\config\TBFDesk2.toml"; $dk = (Get-Content C:\src\tbf-test\dk.txt -Raw).Trim(); "server=" + (Select-String $f -Pattern "^custom-rendezvous-server = .10\.0\.2\.2." -Quiet); "dk=" + (Select-String $f -Pattern $dk -SimpleMatch -Quiet); "mgmt=" + (Select-String $f -Pattern "^nemo-management-enabled = .Y." -Quiet)')
echo "$svc" | grep -q 'server=True' && echo "$svc" | grep -q 'dk=True' && echo "$svc" | grep -q 'mgmt=True' \
  && ok "the SERVICE's config carries the server, THIS run's device key and the management switch" || { bad "service config: $svc"; fail=1; }
id=$(vps '& "C:\Program Files\TBFDesk\TBFDesk.exe" --get-id | Out-String' | grep -E '^[0-9]{6,}$' | tail -1)
[ "$id" = "$VMID" ] || say "note: the machine came back as $id (key bound to $VMID)"
# fresh: the service confirmed a policy after T0 -- only a poll signed with the new key gets one
fresh() { local t; t=$(peer_field "$VMID" policy_applied.service.confirmed_at); [ "${t:-0}" -ge "$T0" ] 2>/dev/null && echo fresh || echo "stale:${t:-none}"; }
f=$(wait_for_value fresh 180 fresh)
[ "$f" = fresh ] && ok "the service polled and confirmed a policy after this run started" || { bad "no fresh policy confirmation ($f)"; fail=1; }
auth=$(peer_field "$VMID" auth_mode)
[ "$auth" = device-key ] && ok "registered and authenticated with its device key -- no GUI opened" || { bad "auth_mode '$auth'"; fail=1; }
st=$(wait_for_value in_sync 60 peer_field "$VMID" policy_applied.service.state)
[ "$st" = in_sync ] && ok "managed: the server shows the policy it applied (in_sync)" || { bad "#43 state '$st'"; fail=1; }

# 5. re-provision an installed client from a pipe
out=$(vps "Get-Content '$SETUP' | & 'C:\Program Files\TBFDesk\TBFDesk.exe' --import-setup - | Out-String; 'exit=' + \$LASTEXITCODE")
if echo "$out" | grep -q '^exit=0' && echo "$out" | grep -q 'TBFDesk service provisioned'; then ok "re-provisioning from a pipe (--import-setup -) configures the service"
else bad "--import-setup - : $(echo "$out" | grep -vF "$DK" | tr '\n' '|' | head -c 300)"; fail=1; fi
leak=$(vps "$LEAK_PS" | sed -n 's/^hits=//p')
[ "${leak:-x}" = 0 ] && ok "no device key written into the console user's (possibly roaming) config" || { bad "the console user's config holds the device key (${leak:-unreadable} files)"; fail=1; }

# 6. the user opens the window for the first time: it syncs with the service, but the device
#    key must still not land in their profile -- nor in any log, theirs or the service's
vmctl put "$TBF_TESTS/gui/win/run-ui-debug.cmd" 'C:/src/tbf-test/run-ui-debug.cmd' >/dev/null 2>&1
vmctl put "$TBF_TESTS/gui/win/stop-ui.ps1" 'C:/src/tbf-test/stop-ui.ps1' >/dev/null 2>&1
vmctl gui 'C:\src\tbf-test\run-ui-debug.cmd' >/dev/null 2>&1; sleep 25
ui=$(vps '"ui=" + @(Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq "tbfdesk.exe" -and $_.CommandLine -notmatch "--" }).Count')
leak=$(vps "$LEAK_PS"); lf=$(echo "$leak" | sed -n 's/^files=//p'); lh=$(echo "$leak" | sed -n 's/^hits=//p')
if ! echo "$ui" | grep -q '^ui=[1-9]'; then bad "the main window did not start ($ui)"; fail=1
elif [ "${lh:-x}" = 0 ]; then ok "main window opened (synced, $lf config files): still no device key in the user's profile"
elif [ -n "$lh" ]; then
  # Pre-existing (upstream config sync), not this feature's -- see OPEN-TODOS #48.
  known "OPEN-TODOS #48: the opened window copies the service's config, device key included, into the user's profile ($lh of $lf files)" || fail=1
else bad "could not read the user's config after opening the window"; fail=1; fi
logs=$(vps '$dk = (Get-Content C:\src\tbf-test\dk.txt -Raw).Trim(); $files = @(Get-ChildItem C:\Users\tbf\AppData\Roaming\TBFDesk\log, C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\TBFDesk\log, C:\Windows\System32\config\systemprofile\AppData\Roaming\TBFDesk\log, C:\src\tbf-test -Recurse -File -Include *.log, *.txt -EA SilentlyContinue | Where-Object { $_.Name -ne "dk.txt" }); "files=" + $files.Count; "hits=" + @($files | Select-String -Pattern $dk -SimpleMatch -List).Count')
lf=$(echo "$logs" | sed -n 's/^files=//p'); lh=$(echo "$logs" | sed -n 's/^hits=//p')
[ "${lh:-x}" = 0 ] && [ "${lf:-0}" -gt 0 ] && ok "no device key in any log or captured output ($lf files: user, service, installer, debug UI)" \
  || { bad "device key found in ${lh:-?} of ${lf:-?} log/output files"; fail=1; }
vps '& C:\src\tbf-test\stop-ui.ps1' >/dev/null

[ $fail -eq 0 ] && { rm -rf "$T"; exit 0; } || { say "artifacts kept in $T (key files removed)"; exit 1; }

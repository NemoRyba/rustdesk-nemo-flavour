#!/usr/bin/env bash
# #43 end to end: the Peers panel shows the policy a client ACTUALLY applied.
# Win11 VM (service role, device key bound) + lab hbbs. Requires the windows GUI stage first
# (client >= 1.4.18 installed and provisioned). Restores the lab's policies afterwards.
#   T1 assign named policy A        -> row: in_sync, source device, name A
#   T2 switch to B                  -> in_sync, name B
#   T4 client refuses (rollback)    -> refused + reason; restore -> in_sync again
#   T6 service stopped > 2 min      -> stale; restart -> in_sync        (TBF_FULL=1 only)
#   GUI the dashboard renders the state badge (data-policy-state) in a headless browser
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
VMID="${TBF_VM_ID:-12513041}"
vm_ready || { say "SKIP: Windows VM not up"; exit 2; }
lab_hbbs_pid >/dev/null || { say "SKIP: no lab hbbs running"; exit 2; }
ver=$(peer_field "$VMID" client_version)
case "$ver" in ""|1.4.1[0-7]) say "SKIP: $VMID runs '$ver' (needs >= 1.4.18 -- run the windows GUI stage first)"; exit 2;; esac
T=$(mktemp -d "$TBF_OUT/policy-e2e.XXXX"); fail=0
vps() { vmctl ps "$1" 2>&1 | tr -d '\r'; }
svc_state() { echo "$(peer_field "$VMID" policy_applied.service.state):$(peer_field "$VMID" policy_applied.service.name)"; }
SVC_CFG='C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\TBFDesk\config\TBFDesk2.toml'

admin_api GET /nemo/api/policies > "$T/orig.json"
RESTORED=0
restore() {
  [ "$RESTORED" = 1 ] && return 0; RESTORED=1
  admin_api POST /nemo/api/policies/device "{\"peer_id\":\"$VMID\",\"policy_name\":null}" >/dev/null
  admin_api PUT /nemo/api/policies "$(python3 -c 'import json,sys; print(json.dumps({"policies": json.load(open(sys.argv[1])).get("policies") or {}}))' "$T/orig.json")" >/dev/null
  vps "\$f='$SVC_CFG'; if (Select-String \$f -Pattern '^nemo-policy-issued-ts = ''99' -Quiet) { Stop-Service TBFDesk -Force; (Get-Content \$f) | Where-Object { \$_ -notmatch '^nemo-policy-issued-ts = ' } | Set-Content \$f; Start-Service TBFDesk }" >/dev/null
}
trap restore EXIT

admin_api PUT /nemo/api/policies "$(python3 - "$T/orig.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])).get("policies") or {}
p["tbf-suite-A"] = {"allow_user_override": False, "options": {"enable-audio": "N"}}
p["tbf-suite-B"] = {"allow_user_override": False, "options": {"enable-audio": "Y", "enable-clipboard": "N"}}
print(json.dumps({"policies": p}))
PY
)" >/dev/null

# T1
admin_api POST /nemo/api/policies/device "{\"peer_id\":\"$VMID\",\"policy_name\":\"tbf-suite-A\"}" >/dev/null
got=$(wait_for_value "in_sync:tbf-suite-A" 120 svc_state)
[ "$got" = "in_sync:tbf-suite-A" ] && [ "$(peer_field "$VMID" policy_applied.service.source)" = device ] \
  && ok "T1 assigned policy A: the row shows it applied (in_sync, device policy A)" \
  || { bad "T1 expected in_sync:tbf-suite-A from source device, got '$got'"; fail=1; }

# T2 (watch for the 'pending' window on the way; informational -- it lasts at most one poll)
admin_api POST /nemo/api/policies/device "{\"peer_id\":\"$VMID\",\"policy_name\":\"tbf-suite-B\"}" >/dev/null
seen=""; end=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$end" ]; do
  s=$(svc_state); case "$s" in pending:*) seen=pending;; in_sync:tbf-suite-B) break;; esac; sleep 3
done
[ "$s" = "in_sync:tbf-suite-B" ] && ok "T2 switched to B: the row followed (${seen:-pending window not caught between polls}, then in_sync B)" \
  || { bad "T2 expected in_sync:tbf-suite-B, got '$s'"; fail=1; }

# T4: make the client refuse -- its anti-rollback mark a year ahead
future=$(( $(date +%s) + 31536000 ))
vps "\$f='$SVC_CFG'; Stop-Service TBFDesk -Force; Start-Sleep 2; \$c = Get-Content \$f | Where-Object { \$_ -notmatch '^nemo-policy-issued-ts = ' }; \$i = [array]::IndexOf(\$c, '[options]'); \$c = \$c[0..\$i] + \"nemo-policy-issued-ts = '$future'\" + \$c[(\$i+1)..(\$c.Length-1)]; \$c | Set-Content \$f; Start-Service TBFDesk; 'ok'" >/dev/null
got=$(wait_for_value refused 150 peer_field "$VMID" policy_applied.service.state)
code=$(peer_field "$VMID" policy_applied.service.refused_code)
[ "$got" = refused ] && [ "$code" = rollback ] && ok "T4 a refused policy is visible: refused, reason 'rollback'" \
  || { bad "T4 expected refused/rollback, got '$got'/'$code'"; fail=1; }
vps "\$f='$SVC_CFG'; Stop-Service TBFDesk -Force; Start-Sleep 2; (Get-Content \$f) | Where-Object { \$_ -notmatch '^nemo-policy-issued-ts = ' } | Set-Content \$f; Start-Service TBFDesk; 'ok'" >/dev/null
got=$(wait_for_value in_sync 150 peer_field "$VMID" policy_applied.service.state)
[ "$got" = in_sync ] && ok "T4 after the fix the client applies again (in_sync)" || { bad "T4 recovery: '$got'"; fail=1; }

# T6 (slow)
if [ "${TBF_FULL:-0}" = 1 ]; then
  vps 'Stop-Service TBFDesk -Force; "ok"' >/dev/null
  got=$(wait_for_value stale 200 peer_field "$VMID" policy_applied.service.state)
  vps 'Start-Service TBFDesk; "ok"' >/dev/null
  [ "$got" = stale ] && ok "T6 a silent client turns stale" || { bad "T6 expected stale, got '$got'"; fail=1; }
  wait_for_value in_sync 150 peer_field "$VMID" policy_applied.service.state >/dev/null
else say "T6 (stale after 2 min offline) skipped -- set TBF_FULL=1"; fi

# Dashboard badge in a real (headless) browser
if command -v brave >/dev/null && command -v node >/dev/null; then
  PORT=9333; PROFILE="$T/brave"
  brave --headless=new --remote-debugging-port=$PORT --user-data-dir="$PROFILE" --ignore-certificate-errors \
        --no-first-run "$LAB_API/nemo/admin" >"$T/brave.log" 2>&1 & BRAVE=$!; disown; sleep 4
  CDP="env CDP_PORT=$PORT node $TBF_VM/scripts/cdp.mjs"
  $CDP eval "localStorage.setItem('nemoAdminToken', $(lab_token | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')); location.reload(); true" >/dev/null 2>&1
  sleep 6
  badge=$($CDP eval "(() => { for (const tr of document.querySelectorAll('tr')) { if (tr.textContent.includes('$VMID')) { const b = tr.querySelector('[data-policy-state]'); return b ? b.dataset.policyState + '|' + b.textContent : 'no-badge'; } } return 'no-row'; })()" 2>&1 | tr -d '"')
  kill $BRAVE 2>/dev/null; for i in $(seq 1 20); do kill -0 $BRAVE 2>/dev/null || break; sleep 0.3; done
  case "$badge" in in_sync\|*) ok "dashboard renders the state badge for $VMID ($badge)";;
    *) bad "dashboard badge for $VMID: '$badge'"; fail=1;; esac
else say "dashboard badge check skipped (brave/node missing)"; fi

restore   # BEFORE removing $T: it reads the saved policies from there
[ $fail -eq 0 ] && { rm -rf "$T" 2>/dev/null; exit 0; } || { say "artifacts kept in $T"; exit 1; }

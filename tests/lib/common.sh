# Shared helpers for the TBFDesk test suite (sourced by tests/run-all.sh and every stage).
# Lab-only: it talks to the local lab hbbs and the Win11 test VM, never to production.

TBF_ROOT="${TBF_ROOT:-/projects/rustdesk/rustdesk-nemo-flavour}"
TBF_VM="${TBF_VM:-/projects/rustdesk/vm}"
TBF_CLIENT="$TBF_ROOT/rustdesk-client-nemo"
TBF_SERVER="$TBF_ROOT/rustdesk-server-nemo"
TBF_TESTS="$TBF_ROOT/tests"
TBF_OUT="${TBF_OUT:-/tmp/tbf-tests}"          # artifacts: logs, screenshots, results
mkdir -p "$TBF_OUT"
TBF_RESULTS="${TBF_RESULTS:-$TBF_OUT/results.tsv}"

say()  { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; TBF_STAGE_FAILED=1; }
note_result() {  # <stage> <PASS|FAIL|SKIP> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TBF_RESULTS"
}

# ---- lab server -------------------------------------------------------------------
lab_hbbs_pid() {
  for p in /proc/[0-9]*; do
    e=$(readlink "$p/exe" 2>/dev/null) || continue
    e=${e/ (deleted)/}
    case "$e" in */rustdesk-server-nemo/target/release/hbbs) echo "${p#/proc/}"; return 0;; esac
  done
  return 1
}

# The lab admin token, read from the running lab hbbs' argv. Never printed.
lab_token() {
  local pid; pid=$(lab_hbbs_pid) || return 1
  tr '\0' '\n' < "/proc/$pid/cmdline" | grep -A1 -x -- '--nemo-api-token' | tail -1
}

LAB_API="${LAB_API:-https://127.0.0.1:31120}"
admin_api() {  # <method> <path> [json-body]
  local method=$1 api_path=$2 body=${3:-}
  local tok; tok=$(lab_token) || { echo '{"error":"no lab hbbs running"}'; return 1; }
  if [ -n "$body" ]; then
    curl -sk -m 20 -X "$method" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$body" "$LAB_API$api_path"
  else
    curl -sk -m 20 -X "$method" -H "Authorization: Bearer $tok" "$LAB_API$api_path"
  fi
}

lab_server_key() { cat /projects/rustdesk/vm/lab2/id_ed25519.pub 2>/dev/null; }

# Issue a fresh lab device key bound to <peer_id>, after deleting keys from earlier runs
# with the same label. Prints the API response JSON (contains the private key: keep it in
# the run's artifact dir only, never in the repo).
issue_device_key() {  # <peer_id> <label> <id_server> <relay> <api_server>
  local peer=$1 label=$2 ids=$3 relay=$4 api=$5
  admin_api GET /nemo/api/device-keys | python3 -c '
import sys, json
d = json.load(sys.stdin); ks = d.get("keys", d) if isinstance(d, dict) else d
for k in ks:
    if isinstance(k, dict) and k.get("label") == sys.argv[1]:
        print(k["id"])' "$label" | while read -r kid; do
    admin_api POST "/nemo/api/device-keys/$kid/delete" '{}' >/dev/null
  done
  admin_api POST /nemo/api/device-keys "$(python3 -c '
import json, sys
print(json.dumps({"label": sys.argv[1], "peer_id": sys.argv[2],
  "setup": {"internal": {"id_server": sys.argv[3], "relay_server": sys.argv[4], "api_server": sys.argv[5]}}}))' \
    "$label" "$peer" "$ids" "$relay" "$api")"
}

# TBFDesk2.toml for a client from an issue_device_key response.
client_config_from_key() {  # <response.json>
  python3 - "$1" <<'PY'
import sys, json, base64
d = json.load(open(sys.argv[1])); s = d["setup_internal"]; st = s["setup_string"] if isinstance(s, dict) else s
b = json.loads(base64.b64decode(st.split(":", 1)[1])); srv = b["server"]
print(f"""rendezvous_server = '{srv['id_server']}:21116'
nat_type = 0
serial = 0
unlock_pin = ''
trusted_devices = ''

[options]
custom-rendezvous-server = '{srv['id_server']}'
relay-server = '{srv['relay_server']}'
api-server = '{srv['api_server']}'
nemo-management-server = '{srv['api_server']}'
key = '{srv['key']}'
nemo-management-public-key = '{srv['key']}'
nemo-api-cert-fingerprint = '{srv['api_cert_fingerprint']}'
nemo-management-enabled = 'Y'
nemo-device-key = '{b['device_key']}'""")
PY
}

# JSON field of one peer from GET /nemo/api/peers, e.g. peer_field 12513041 policy_applied.service.state
peer_field() {  # <id> <dotted.path>
  admin_api GET /nemo/api/peers | python3 -c '
import sys, json
d = json.load(sys.stdin); peers = d.get("peers", d) if isinstance(d, dict) else d
for p in peers:
    if p.get("id") == sys.argv[1]:
        v = p
        for part in sys.argv[2].split("."):
            v = v.get(part) if isinstance(v, dict) else None
        print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list)) else v)); break' "$1" "$2"
}

# Wait until <cmd...> prints a line equal to <want>, polling every 5 s up to <secs>.
wait_for_value() {  # <want> <secs> <cmd...>
  local want=$1 secs=$2; shift 2
  local deadline=$(( $(date +%s) + secs )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$("$@" 2>/dev/null | tail -1)
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    sleep 5
  done
  echo "$got"; return 1
}

# ---- Windows test VM ----------------------------------------------------------------
vmctl() { "$TBF_VM/scripts/vmctl.sh" "$@"; }
vm_ready() { vmctl status 2>/dev/null | grep -q '^ssh=ready'; }

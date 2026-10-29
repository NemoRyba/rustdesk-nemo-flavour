#!/usr/bin/env bash
# TBFDesk test suite -- one command for every automated check, from unit tests to real
# clicks on the Windows VM. See tests/README.md for what each stage proves.
#
#   tests/run-all.sh                 unit + contract + static + Linux GUI   (default)
#   tests/run-all.sh --quick         unit + contract + static only           (no display, no lab)
#   tests/run-all.sh --all           everything, incl. the Win11 VM tests (unattended provisioning,
#                                    GUI) and the #43 e2e
#   tests/run-all.sh --only <stage>  one stage (repeatable)
#   tests/run-all.sh --installer 'C:\src\dist\tbfdesk-1.4.18-x64-install.exe'   (Windows stage)
#   TBF_FULL=1                       also the slow checks (e.g. #43 'stale' after 2 min offline)
#
# Stage exit codes: 0 pass, 2 skipped (prerequisite missing), anything else fail.
# Artifacts (logs, screenshots of failures): $TBF_OUT (default /tmp/tbf-tests).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

QUICK=(unit-server unit-client contract static-ui server-installer)
DEFAULT=("${QUICK[@]}" build-linux sciter-parse gui-linux)
ALL=("${DEFAULT[@]}" gui-windows-provision gui-windows e2e-policy)
STAGES=("${DEFAULT[@]}"); ONLY=(); INSTALLER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) STAGES=("${QUICK[@]}");;
    --all) STAGES=("${ALL[@]}");;
    --only) ONLY+=("$2"); shift;;
    --installer) INSTALLER="$2"; shift;;
    -h|--help) sed -n '2,15p' "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 64;;
  esac; shift
done
[ ${#ONLY[@]} -gt 0 ] && STAGES=("${ONLY[@]}")

RUN_ID=$(date +%Y%m%d-%H%M%S)
export TBF_OUT="$TBF_OUT/$RUN_ID"; mkdir -p "$TBF_OUT"
export TBF_RESULTS="$TBF_OUT/results.tsv"; : > "$TBF_RESULTS"

stage_cmd() {
  case "$1" in
    unit-server)  (cd "$TBF_SERVER" && cargo test --release 2>&1 | tee "$TBF_OUT/unit-server.log" | grep -E '^test result|FAILED|panicked' ; exit "${PIPESTATUS[0]}");;
    unit-client)  (cd "$TBF_CLIENT" && source "$HERE/lib/client-env.sh" && cargo test --release --features "$TBF_CLIENT_FEATURES" --lib 2>&1 | tee "$TBF_OUT/unit-client.log" | grep -E '^test result|FAILED|panicked' ; exit "${PIPESTATUS[0]}");;
    contract)     python3 "$HERE/contracts/check_policy_report_contract.py";;
    static-ui)    bash "$HERE/static/check_inline_generator.sh";;
    server-installer) bash "$HERE/static/check_server_installer.sh";;
    build-linux)  (cd "$TBF_CLIENT" && source "$HERE/lib/client-env.sh" && cargo build --release --features "$TBF_CLIENT_FEATURES" 2>&1 | tee "$TBF_OUT/build-linux.log" | grep -E '^error|Finished' ; exit "${PIPESTATUS[0]}");;
    sciter-parse) bash "$HERE/gui/sciter_parse.sh";;
    gui-linux)    bash "$HERE/gui/linux_client.sh";;
    gui-windows-provision) bash "$HERE/gui/windows_provision.sh" ${INSTALLER:+"$INSTALLER"};;
    gui-windows)  bash "$HERE/gui/windows_client.sh" ${INSTALLER:+"$INSTALLER"};;
    e2e-policy)   bash "$HERE/e2e/policy_applied.sh";;
    *) echo "unknown stage $1"; return 64;;
  esac
}

declare -A RESULT DURATION
for s in "${STAGES[@]}"; do
  printf '\n\033[1m== %s\033[0m\n' "$s"
  t0=$(date +%s)
  stage_cmd "$s"; rc=$?
  DURATION[$s]=$(( $(date +%s) - t0 ))
  case $rc in 0) RESULT[$s]=PASS;; 2) RESULT[$s]=SKIP;; *) RESULT[$s]=FAIL;; esac
  note_result "$s" "${RESULT[$s]}" "${DURATION[$s]}s"
done

printf '\n\033[1m== Summary (%s)\033[0m\n' "$RUN_ID"
fails=0
for s in "${STAGES[@]}"; do
  case ${RESULT[$s]} in PASS) c=32;; SKIP) c=33;; *) c=31; fails=$((fails + 1));; esac
  printf '  \033[%sm%-5s\033[0m %-13s %4ss\n' "$c" "${RESULT[$s]}" "$s" "${DURATION[$s]}"
done
echo "  artifacts: $TBF_OUT"
exit $(( fails > 0 ))

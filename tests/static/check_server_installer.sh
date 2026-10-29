#!/usr/bin/env bash
# The server tarball's install.sh, exercised for real in a throwaway Ubuntu 24.04 container
# (sudo and systemctl are recording shims; every file operation is real). Guards the 1.1.15
# installer bugs: binaries to /usr/local/bin while the unit ran /usr/bin/hbbs (upgrades kept
# the OLD binary), and the unit overwritten (dropped --nemo-client-api-bind -> 21121 gone).
# Usage: check_server_installer.sh [tarball]   (default: dist/tbfdesk-server-<ver>-linux-x86_64.tar.gz)
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
VER=$(grep -m1 '^version' "$TBF_SERVER/Cargo.toml" | cut -d'"' -f2)
TARBALL="${1:-$TBF_ROOT/dist/tbfdesk-server-$VER-linux-x86_64.tar.gz}"
IMAGE="${TBF_UBUNTU_IMAGE:-localhost/nemo-gui:latest}"
command -v podman >/dev/null || { say "SKIP: podman missing"; exit 2; }
[ -f "$TARBALL" ] || { say "SKIP: no tarball at $TARBALL (dist/pkg-server.sh $VER dist)"; exit 2; }
podman image exists "$IMAGE" || { say "SKIP: image $IMAGE missing"; exit 2; }

# -i is essential: without it bash -s reads an EMPTY script and "passes" having run nothing.
out=$(podman run --rm -i -v "$TARBALL:/pkg.tar.gz:ro" "$IMAGE" bash -s 2>&1 <<'IN'
set -u
fails=0
pass() { echo "    OK   $*"; }
nope() { echo "    FAIL $*"; fails=$((fails+1)); }
mkdir -p /t && tar xzf /pkg.tar.gz -C /t && P=$(ls -d /t/tbfdesk-server-*)
printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo
cat > /usr/local/bin/systemctl <<'E'
#!/bin/sh
echo "systemctl $*" >> /tmp/systemctl.log
[ "$1" = is-enabled ] && { [ -f /tmp/enabled ]; exit $?; }
exit 0
E
chmod +x /usr/local/bin/sudo /usr/local/bin/systemctl
NEW=$(sha256sum "$P/bin/hbbs" | cut -c1-64)
U=/etc/systemd/system/rustdesk-hbbs-nemo.service; R=/etc/systemd/system/rustdesk-hbbr-nemo.service; ENVF=/etc/tbfdesk/hbbs.env
execstart() { grep -m1 '^ExecStart=' "$1"; }

# A: fresh install
out=$("$P/install.sh" 2>&1)
[ "$(sha256sum /usr/bin/hbbs | cut -c1-64)" = "$NEW" ] && pass "A fresh: new hbbs at /usr/bin" || nope "A fresh: /usr/bin/hbbs missing or wrong"
case "$(execstart "$U")" in "ExecStart=/usr/bin/hbbs \\") pass "A fresh: hbbs unit runs /usr/bin/hbbs";; *) nope "A fresh: hbbs unit $(execstart "$U")";; esac
[ "$(execstart "$R")" = "ExecStart=/usr/bin/hbbr -k _" ] && pass "A fresh: hbbr unit runs /usr/bin/hbbr -k _" || nope "A fresh: hbbr unit $(execstart "$R")"
[ "$(stat -c %a "$ENVF" 2>/dev/null)" = 600 ] && grep -qx 'NEMO_CLIENT_API_BIND=0.0.0.0:21121' "$ENVF" \
  && pass "A fresh: hbbs.env template (0600) carries NEMO_CLIENT_API_BIND=0.0.0.0:21121" || nope "A fresh: env template wrong"
id rustdesk >/dev/null 2>&1 && [ "$(stat -c %U /var/lib/rustdesk-server)" = rustdesk ] \
  && pass "A fresh: service user + state dir owned by rustdesk" || nope "A fresh: user/dir"
echo "$out" | grep -q 'First install' && pass "A fresh: tells the operator it is a first install" || nope "A fresh: wrong next-step text"

# B: upgrade over a 1.1.15-style install whose unit was customised and pointed elsewhere
echo OLD > /usr/bin/hbbs
sed -i 's#^ExecStart=/usr/bin/hbbs#ExecStart=/usr/local/bin/hbbs#' "$U"; echo '# operator-custom-line' >> "$U"
printf 'NEMO_API_TOKEN=keepme\nTBFDESK_RELAY=1.2.3.4:21117\n' > "$ENVF"; touch /tmp/enabled; : > /tmp/systemctl.log
out=$("$P/install.sh" 2>&1)
case "$(execstart "$U")" in "ExecStart=/usr/bin/hbbs \\") pass "B upgrade: unit re-pointed to where the binary is";; *) nope "B upgrade: $(execstart "$U")";; esac
grep -qx '# operator-custom-line' "$U" && pass "B upgrade: the operator's unit customisation is kept" || nope "B upgrade: unit was overwritten"
[ "$(sha256sum /usr/bin/hbbs | cut -c1-64)" = "$NEW" ] && pass "B upgrade: old binary replaced" || nope "B upgrade: old binary still there"
[ "$(cat "$ENVF")" = "$(printf 'NEMO_API_TOKEN=keepme\nTBFDESK_RELAY=1.2.3.4:21117')" ] && pass "B upgrade: existing hbbs.env untouched" || nope "B upgrade: hbbs.env modified"
echo "$out" | grep -q 'systemctl restart rustdesk-hbbr-nemo rustdesk-hbbs-nemo' && ! grep -q '^systemctl restart' /tmp/systemctl.log \
  && pass "B upgrade: prints the restart command, does not restart on its own" || nope "B upgrade: restart behaviour"

# C: RESTART=1 restarts
: > /tmp/systemctl.log; RESTART=1 "$P/install.sh" >/dev/null 2>&1
grep -q '^systemctl restart rustdesk-hbbr-nemo rustdesk-hbbs-nemo' /tmp/systemctl.log && pass "C RESTART=1 restarts both services" || nope "C no restart"

# D: idempotent
cp "$U" /tmp/u1; "$P/install.sh" >/dev/null 2>&1
cmp -s "$U" /tmp/u1 && pass "D re-running changes nothing" || nope "D second run changed the unit"

# E: another prefix -> the unit follows
PREFIX=/usr/local/bin "$P/install.sh" >/dev/null 2>&1
case "$(execstart "$U")" in "ExecStart=/usr/local/bin/hbbs \\") pass "E PREFIX=/usr/local/bin: unit follows";; *) nope "E: $(execstart "$U")";; esac
[ "$(sha256sum /usr/local/bin/hbbs | cut -c1-64)" = "$NEW" ] && pass "E PREFIX=/usr/local/bin: binary there" || nope "E: binary missing"
exit $fails
IN
)
rc=$?
echo "$out"
# A silent pass is a failure: every scenario must have reported.
n=$(echo "$out" | grep -cE '^    (OK|FAIL) ')
[ "$n" -ge 15 ] || { bad "only $n installer checks ran (expected 15)"; exit 1; }
exit $rc

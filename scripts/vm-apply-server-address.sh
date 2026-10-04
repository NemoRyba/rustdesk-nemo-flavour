#!/usr/bin/env bash
# Re-point the TBFDesk server VM (ubuntu24dev) after the 2026-09-04 move into the
# middle segment: LAN address 192.168.1.14, public address 85.126.226.2.
#
# What it changes (each file is backed up to <file>.bak-<date> first):
#   1. /etc/systemd/system/rustdesk-hbbs-nemo.service
#        -r <old>:21117            ->  -r $PUBLIC_IP:21117   (relay handed to NON-LAN peers)
#        + --local-ip $LAN_IP                                (relay handed to LAN peers, see TOPOLOGY-DEPLOYMENT.md)
#   2. the VM's own host-client configs (dev + gdm greeter):
#        every old server address   ->  $LAN_IP              (rendezvous, relay-server, api-server, nemo-management-server)
#   3. daemon-reload + restart hbbs / hbbr / host client, then a reachability check.
#
# Usage (on the VM, as dev):   sudo -E bash scripts/vm-apply-server-address.sh [-n]
#   -n  dry run: print what would change, touch nothing.
# Override addresses with env vars: LAN_IP, PUBLIC_IP, OLD_IPS (space-separated), DC_IP.
set -euo pipefail

LAN_IP="${LAN_IP:-192.168.1.14}"
PUBLIC_IP="${PUBLIC_IP:-85.126.226.2}"
OLD_IPS="${OLD_IPS:-192.168.0.176 192.168.1.126}"
DC_IP="${DC_IP:-192.168.0.151}"
UNIT=/etc/systemd/system/rustdesk-hbbs-nemo.service
CLIENT_CONFIGS=(/home/dev/.config/rustdesk/RustDesk2.toml /var/lib/gdm3/.config/rustdesk/RustDesk2.toml)
STAMP=$(date +%F)
DRY=0
[ "${1:-}" = "-n" ] && DRY=1

if [ "$DRY" = 0 ] && [ "$(id -u)" != 0 ]; then
  echo "run with sudo (or -n for a dry run)" >&2
  exit 1
fi

say() { printf '\n== %s\n' "$*"; }

# --- 1. hbbs unit -------------------------------------------------------------
say "hbbs unit: $UNIT"
[ -f "$UNIT" ] || { echo "missing $UNIT" >&2; exit 1; }
new_unit=$(cat "$UNIT")
for old in $OLD_IPS; do
  new_unit=${new_unit//-r $old:21117/-r $PUBLIC_IP:21117}
done
if grep -q -- '--local-ip' <<<"$new_unit"; then
  new_unit=$(sed -E "s/--local-ip [^ ]+/--local-ip $LAN_IP/" <<<"$new_unit")
else
  new_unit=$(sed -E "s/(-r $PUBLIC_IP:21117)/\1 --local-ip $LAN_IP/" <<<"$new_unit")
fi
if ! grep -q -- "-r $PUBLIC_IP:21117 --local-ip $LAN_IP" <<<"$new_unit"; then
  echo "could not rewrite ExecStart — edit it by hand:" >&2
  grep ExecStart "$UNIT" >&2
  exit 1
fi
if [ "$new_unit" != "$(cat "$UNIT")" ]; then
  diff <(cat "$UNIT") <(printf '%s\n' "$new_unit") || true
  if [ "$DRY" = 0 ]; then
    cp -a "$UNIT" "$UNIT.bak-$STAMP"
    printf '%s\n' "$new_unit" > "$UNIT"
  fi
else
  echo "already correct"
fi

# --- 2. host-client configs ---------------------------------------------------
for cfg in "${CLIENT_CONFIGS[@]}"; do
  say "client config: $cfg"
  [ -f "$cfg" ] || { echo "not present, skipped"; continue; }
  new_cfg=$(cat "$cfg")
  for old in $OLD_IPS; do
    new_cfg=${new_cfg//$old/$LAN_IP}
  done
  # relay-server must be the bare address: hbbs string-compares it with --local-ip
  new_cfg=$(sed -E "s/^(relay-server = ')$LAN_IP:[0-9]+(')/\1$LAN_IP\2/" <<<"$new_cfg")
  if [ "$new_cfg" != "$(cat "$cfg")" ]; then
    diff <(cat "$cfg") <(printf '%s\n' "$new_cfg") || true
    if [ "$DRY" = 0 ]; then
      cp -a "$cfg" "$cfg.bak-$STAMP"
      printf '%s\n' "$new_cfg" > "$cfg"   # cp -a kept owner/mode on the backup; > keeps them on the original
    fi
  else
    echo "already correct"
  fi
done

[ "$DRY" = 1 ] && { say "dry run — nothing applied"; exit 0; }

# --- 3. restart + verify ------------------------------------------------------
say "restart services"
systemctl daemon-reload
systemctl restart rustdesk-hbbs-nemo.service rustdesk-hbbr-nemo.service
systemctl restart rustdesk-nemo.service || echo "(host client unit not restarted — check its name)"
sleep 2
systemctl --no-pager --lines=0 status rustdesk-hbbs-nemo.service rustdesk-hbbr-nemo.service rustdesk-nemo.service | grep -E 'service|Active'

say "listeners (expect 21115/21116 tcp, 21116 udp, 21117 tcp, 21120 tcp)"
ss -lntup | grep -E ':2111[5-9]|:21120' || echo "nothing listening on the TBFDesk ports"

say "nemo-api over the LAN address"
curl -sk --max-time 5 -o /dev/null -w "https://$LAN_IP:21120/nemo/admin -> HTTP %{http_code}\n" "https://$LAN_IP:21120/nemo/admin" || echo "nemo-api not reachable on $LAN_IP:21120"

say "LDAPS to the DC through router B (needs the DMZ->LAN 636 rule)"
if timeout 5 bash -c "exec 3<>/dev/tcp/$DC_IP/636" 2>/dev/null; then
  echo "$DC_IP:636 reachable"
else
  echo "$DC_IP:636 NOT reachable — logins will fail until router B allows $LAN_IP -> $DC_IP tcp/636"
fi

say "effective hbbs command"
grep ExecStart "$UNIT"

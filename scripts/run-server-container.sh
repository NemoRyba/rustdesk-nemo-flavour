#!/usr/bin/env bash
# Run the TBFDesk server (hbbs) in a rootless podman container — the "small non-VM"
# server sandbox. Built from an Arch base with the host-compiled hbbs/hbbr copied in
# (matching glibc/openssl), so no in-container toolchain is needed.
#
# Build the image first (from scripts/):  see build-server-container.sh
# Admin GUI after start:  http://<host>:21120/nemo/admin   (enter the --nemo-api-token)
set -euo pipefail
NAME=${NAME:-nemo-server}
TOKEN=${TOKEN:-changeme-admin-token}
podman rm -f "$NAME" >/dev/null 2>&1 || true
podman run -d --name "$NAME" \
  -p 21115:21115 -p 21116:21116/tcp -p 21116:21116/udp -p 21117:21117 \
  -p 21118:21118 -p 21119:21119 -p 21120:21120 \
  -v "${NAME}-data:/srv" \
  localhost/nemo-hbbs \
  hbbs -k _ --generate-key Y --nemo-api Y --nemo-api-bind 0.0.0.0:21120 --nemo-api-token "$TOKEN" \
       --nemo-api-allow-insecure Y --key-exchange offer -r 127.0.0.1
echo "Started $NAME. Admin GUI: http://127.0.0.1:21120/nemo/admin (token: $TOKEN)"
echo "For production: put TLS in front (--nemo-api-tls-cert/-key), use a real token, persist /srv."

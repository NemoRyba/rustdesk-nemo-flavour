#!/usr/bin/env bash
# Build the nemo-hbbs container image: Arch base + the host-built hbbs/hbbr binaries.
# Requires: the server already built on the host (cargo build in rustdesk-server-nemo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/rustdesk-server-nemo"
[ -x "$S/target/debug/hbbs" ] || {
  echo "build the server first:" >&2
  echo "    cd $S && SODIUM_LIB_DIR=/usr/lib SODIUM_SHARED=1 ZSTD_SYS_USE_PKG_CONFIG=1 \\" >&2
  echo "        cargo build --features nemo-management-api" >&2
  exit 1; }
CTX="$(mktemp -d)"; mkdir -p "$CTX/bin"
cp "$S/target/debug/hbbs" "$S/target/debug/hbbr" "$CTX/bin/"
cat > "$CTX/Containerfile" <<'DOCKER'
FROM docker.io/library/archlinux:latest
# libsodium/zstd are runtime deps when hbbs is built against the SYSTEM copies.
# On GCC 16 the vendored libsodium and zstd sources no longer compile (libsodium's
# `make check` fails, zstd's legacy tree ICEs), so the documented host build now
# uses SODIUM_SHARED=1 / ZSTD_SYS_USE_PKG_CONFIG=1 -- which makes these dynamic.
RUN pacman -Sy --noconfirm --needed openssl gcc-libs libsodium zstd && pacman -Scc --noconfirm
COPY bin/hbbs bin/hbbr /usr/local/bin/
RUN chmod +x /usr/local/bin/hbbs /usr/local/bin/hbbr && hbbs --version
WORKDIR /srv
EXPOSE 21115 21116 21117 21118 21119 21120
DOCKER
podman build -t nemo-hbbs -f "$CTX/Containerfile" "$CTX"
rm -rf "$CTX"
echo "Built localhost/nemo-hbbs. Run it with scripts/run-server-container.sh"

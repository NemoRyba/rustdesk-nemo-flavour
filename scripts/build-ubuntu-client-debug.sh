#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.cargo/env" ]; then
  . "$HOME/.cargo/env"
fi

cd "$(dirname "$0")/../rustdesk-client-nemo"
PKG_CONFIG_PATH="$PWD/../pkgconfig" cargo build --features linux-pkg-config

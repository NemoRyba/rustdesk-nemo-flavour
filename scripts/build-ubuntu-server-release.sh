#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.cargo/env" ]; then
  . "$HOME/.cargo/env"
fi

cd "$(dirname "$0")/../rustdesk-server-nemo"
cargo build --release

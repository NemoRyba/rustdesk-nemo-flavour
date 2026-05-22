#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../rustdesk-server-nemo"
cargo build --release

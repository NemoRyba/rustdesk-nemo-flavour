#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../rustdesk-client-nemo"
PKG_CONFIG_PATH="$PWD/../pkgconfig" cargo build --features linux-pkg-config

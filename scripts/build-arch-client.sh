#!/usr/bin/env bash
# Build the TBFDesk client natively on Arch / CachyOS / Manjaro.
#
# Arch ships clang 22, whose AST change broke bindgen for libaom/libvpx: their config
# structs are forward-declared (the `config` union in aom_codec.h) before being defined
# in aom_decoder.h/aom_encoder.h, and bindgen <= 0.72.0 emitted those as opaque, so the
# build died with `error[E0560]: struct aom_codec_dec_cfg has no field named threads`.
# libs/scrap now requires bindgen 0.72.1, which fixes it. If you ever see that error
# again, check that bindgen resolved to >= 0.72.1 (`cargo tree -i bindgen`).
#
# Usage: build-arch-client.sh [--release]
set -euo pipefail

if [ -f "$HOME/.cargo/env" ]; then
  . "$HOME/.cargo/env"
fi

PKGS=(rust clang cmake ninja nasm yasm pkgconf
      aom libvpx libyuv opus
      gtk3 xdotool libxfixes libxcb alsa-lib libpulse
      gstreamer gst-plugins-base pam)

missing=()
for p in "${PKGS[@]}"; do
  pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing packages: ${missing[*]}" >&2
  echo "Install them with:" >&2
  echo "    sudo pacman -S --needed ${missing[*]}" >&2
  exit 1
fi

# libyuv ships no .pc on Arch either, so reuse the one in the workspace. PKG_CONFIG_PATH
# is *prepended* to pkg-config's built-in search path, so the system .pc files (openssl,
# gtk, ...) are still found. The Debian-style -L inside libyuv.pc is a no-op here: -lyuv
# resolves from the default /usr/lib.
# GCC 16 (current on Arch/CachyOS) hits an internal compiler error building the
# vendored libgit2 that libgit2-sys 0.14.2 carries:
#     internal compiler error: in c_addr_space_name, at c-family/c-common.cc:657
# clang compiles it fine, but clang then fails on libsodium's and openssl's vendored
# sources -- so point those two at the system copies instead of building them.
# Without this the whole client build dies in a build script, far from any Rust error.
: "${CC:=clang}"; : "${CXX:=clang++}"
export CC CXX
export SODIUM_LIB_DIR="${SODIUM_LIB_DIR:-/usr/lib}"
export SODIUM_SHARED="${SODIUM_SHARED:-1}"
export OPENSSL_NO_VENDOR="${OPENSSL_NO_VENDOR:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PKG_CONFIG_PATH="$ROOT/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

PROFILE=()
OUT="target/debug/rustdesk"
if [ "${1:-}" = "--release" ]; then
  PROFILE=(--release)
  OUT="target/release/rustdesk"
fi

# hwcodec gives H.264/H.265 (VAAPI encode + ffmpeg decode). It is NOT in `default`, so
# a build without it silently produces a client with only VP8/VP9/AV1 -- no error, just
# missing codecs. The shipped binary has it, so the script must too, or it cannot
# reproduce what is fielded. hwcodec needs a vcpkg tree with static ffmpeg; the AUR
# rustdesk package leaves a usable one behind.
FEATURES="linux-pkg-config,hwcodec"
if [ -z "${VCPKG_ROOT:-}" ]; then
  VCPKG_ROOT="$(ls -d "$HOME"/.cache/yay/rustdesk/src/vcpkg-*/ 2>/dev/null | head -1)"
  VCPKG_ROOT="${VCPKG_ROOT%/}"
fi
if [ -n "${VCPKG_ROOT:-}" ] && [ -d "$VCPKG_ROOT" ]; then
  export VCPKG_ROOT
  echo "hwcodec: using VCPKG_ROOT=$VCPKG_ROOT"
elif [ "${NO_HWCODEC:-0}" = "1" ]; then
  FEATURES="linux-pkg-config"
  echo "WARNING: building WITHOUT hwcodec -- no H.264/H.265 in this client." >&2
else
  echo "ERROR: hwcodec needs a vcpkg tree with static ffmpeg but VCPKG_ROOT is unset" >&2
  echo "       and no ~/.cache/yay/rustdesk/src/vcpkg-* was found." >&2
  echo "       Set VCPKG_ROOT=/path/to/vcpkg, or re-run with NO_HWCODEC=1 to build a" >&2
  echo "       client WITHOUT H.264/H.265 (do not ship that build)." >&2
  exit 1
fi

cd "$ROOT/rustdesk-client-nemo"
cargo build "${PROFILE[@]}" --features "$FEATURES"
echo "Built: $PWD/$OUT (features: $FEATURES)"

# Build environment for the Linux client -- the same one scripts/build-arch-client.sh
# sets (GCC 16 cannot build the vendored C deps; libyuv has no system .pc; hwcodec needs
# a vcpkg ffmpeg). Sourced by the test suite before any cargo call on the client.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export CC="${CC:-clang}" CXX="${CXX:-clang++}"
export SODIUM_LIB_DIR="${SODIUM_LIB_DIR:-/usr/lib}" SODIUM_SHARED="${SODIUM_SHARED:-1}"
export OPENSSL_NO_VENDOR="${OPENSSL_NO_VENDOR:-1}"
# BASH_SOURCE is empty when sourced from zsh; fall back to TBF_ROOT / the known checkout.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _TBF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
else
  _TBF_ROOT="${TBF_ROOT:-/projects/rustdesk/rustdesk-nemo-flavour}"
fi
export PKG_CONFIG_PATH="$_TBF_ROOT/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if [ -z "${VCPKG_ROOT:-}" ]; then
  VCPKG_ROOT="$(ls -d "$HOME"/.cache/yay/rustdesk/src/vcpkg-*/ 2>/dev/null | head -1)"
  VCPKG_ROOT="${VCPKG_ROOT%/}"
fi
if [ -n "${VCPKG_ROOT:-}" ] && [ -d "$VCPKG_ROOT" ]; then
  export VCPKG_ROOT
  export TBF_CLIENT_FEATURES="${TBF_CLIENT_FEATURES:-linux-pkg-config,hwcodec}"
else
  export TBF_CLIENT_FEATURES="${TBF_CLIENT_FEATURES:-linux-pkg-config}"
fi

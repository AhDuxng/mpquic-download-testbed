#!/usr/bin/env bash
# =============================================================================
# File        : common/build_picoquic.sh
# Project     : mpquic-download-testbed
# Description : Build step used by install_picoquic.sh, which also installs the
#               dependencies and verifies the result. Builds picoquicdemo
#               (HTTP/3 client and server with QUIC multipath support) on Linux
#               or macOS, with the per-path statistics patch applied.
#
# Usage       : common/build_picoquic.sh [output_bin_dir]
#               Default output directory: <repo>/bin
#
# Steps       : 1. Clone picoquic into third_party/ and check out PICOQUIC_COMMIT.
#               2. Apply patches/picoquic-mpstat.patch (the tree is reset first,
#                  so the patch always applies to pristine sources).
#               3. Configure with CMake; picotls is fetched at the revision
#                  pinned by picoquic. On macOS, OpenSSL 3 from Homebrew is used.
#               4. Build only picoquicdemo and picolog_t, then copy them out.
#
# Robustness  : A marker file is written only after a successful build. A build
#               directory without it (interrupted build, e.g. a dropped SSH
#               session) is discarded, because truncated object files would
#               otherwise be treated as up to date and break the link step.
#
# Requires    : git, cmake, make, pkg-config, a C compiler, OpenSSL headers.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"

OUT_BIN_DIR="${1:-$ROOT/bin}"
SRC_DIR="$ROOT/third_party/picoquic"
BUILD_DIR="$SRC_DIR/build"
DONE_MARKER="$BUILD_DIR/.build-complete"
PATCH="$ROOT/patches/picoquic-mpstat.patch"
JOBS="$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 2)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. Install it first (see README)." >&2; exit 1; }; }
need git; need cmake; need make; need pkg-config

if [ ! -d "$SRC_DIR/.git" ]; then
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone "$PICOQUIC_REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --quiet origin || true
git -C "$SRC_DIR" checkout --quiet --force "$PICOQUIC_COMMIT"
git -C "$SRC_DIR" clean -fdq -e build

git -C "$SRC_DIR" apply "$PATCH"
echo "Applied $(basename "$PATCH") on picoquic $(git -C "$SRC_DIR" rev-parse --short HEAD)"

if [ -d "$BUILD_DIR" ] && [ ! -f "$DONE_MARKER" ]; then
    echo "Previous build did not complete; removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi
rm -f "$DONE_MARKER"

CMAKE_ARGS=(
    -DPICOQUIC_FETCH_PTLS=Y
    -DCMAKE_BUILD_TYPE=Release
    -Dpicoquic_BUILD_TESTS=OFF
    -DBUILD_PICO_SIM=OFF
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)
if [ "$(uname -s)" = "Darwin" ]; then
    OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
    if [ -n "$OPENSSL_PREFIX" ]; then
        CMAKE_ARGS+=(-DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX")
        export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    fi
fi
cmake -S "$SRC_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_DIR" -j"$JOBS" --target picoquicdemo picolog_t
touch "$DONE_MARKER"

mkdir -p "$OUT_BIN_DIR"
cp "$BUILD_DIR/picoquicdemo" "$OUT_BIN_DIR/"
[ -f "$BUILD_DIR/picolog_t" ] && cp "$BUILD_DIR/picolog_t" "$OUT_BIN_DIR/"
echo "OK: $OUT_BIN_DIR/picoquicdemo"

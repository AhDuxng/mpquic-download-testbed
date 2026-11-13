#!/usr/bin/env bash
# Build picoquicdemo (with the per-path stats patch) on Linux or macOS.
#
# Usage: common/build_picoquic.sh [output_bin_dir]
#   Default output: <repo>/bin/picoquicdemo
#
# Steps: clone picoquic at the pinned commit -> apply patches/picoquic-mpstat.patch
#        -> cmake (picotls fetched automatically, pinned by picoquic) -> build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"

OUT_BIN_DIR="${1:-$ROOT/bin}"
SRC_DIR="$ROOT/third_party/picoquic"
BUILD_DIR="$SRC_DIR/build"
PATCH="$ROOT/patches/picoquic-mpstat.patch"
JOBS="$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 2)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. Install it first (see README)." >&2; exit 1; }; }
need git; need cmake; need make; need pkg-config

# 1. Source at the pinned commit
if [ ! -d "$SRC_DIR/.git" ]; then
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone "$PICOQUIC_REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --quiet origin || true
git -C "$SRC_DIR" checkout --quiet --force "$PICOQUIC_COMMIT"
git -C "$SRC_DIR" clean -fdq -e build

# 2. Patch (checkout --force above reset the tree, so apply cleanly every time)
git -C "$SRC_DIR" apply "$PATCH"
echo "Applied $(basename "$PATCH") on picoquic $(git -C "$SRC_DIR" rev-parse --short HEAD)"

# 3. Configure
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

# 4. Build only what we need
cmake --build "$BUILD_DIR" -j"$JOBS" --target picoquicdemo picolog_t

mkdir -p "$OUT_BIN_DIR"
cp "$BUILD_DIR/picoquicdemo" "$OUT_BIN_DIR/"
[ -f "$BUILD_DIR/picolog_t" ] && cp "$BUILD_DIR/picolog_t" "$OUT_BIN_DIR/"
echo "OK: $OUT_BIN_DIR/picoquicdemo"

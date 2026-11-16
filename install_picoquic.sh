#!/usr/bin/env bash
# =============================================================================
# File        : install_picoquic.sh
# Project     : mpquic-download-testbed
# Description : One-command installation of picoquic for this testbed, on the
#               client and on the server. Installs the build dependencies,
#               builds picoquicdemo at the commit pinned in config.env with the
#               per-path statistics patch, and verifies the resulting binary.
#
# Usage       : ./install_picoquic.sh [--no-deps] [--prefix DIR]
#                 --no-deps     skip package installation (no sudo needed)
#                 --prefix DIR  install directory for the binaries
#                               (default: <repo>/bin)
#
# Supports    : Debian, Ubuntu, Raspberry Pi OS (apt-get); Amazon Linux, RHEL,
#               Fedora (dnf); macOS (Homebrew).
#
# Output      : DIR/picoquicdemo  HTTP/3 client and server, QUIC multipath (-M)
#               DIR/picolog_t     binary log to qlog converter
#               Build time: about 2 minutes on a 2-vCPU server, 5 to 10 minutes
#               on a Raspberry Pi 4. Over SSH, run it detached (see README).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$ROOT/bin"
WITH_DEPS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-deps) WITH_DEPS=0; shift ;;
        --prefix)  PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,/^# =\{10,\}$/p' "$0" | sed '1d;$d;s/^# \{0,1\}//'; exit 0 ;;
        *)         echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
done

install_deps() {
    if [ "$(uname -s)" = "Darwin" ]; then
        command -v brew >/dev/null 2>&1 || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
        brew install cmake pkg-config openssl@3 git
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y build-essential cmake git pkg-config libssl-dev openssl python3
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y gcc gcc-c++ make cmake git pkgconf-pkg-config openssl-devel openssl python3
    else
        echo "Unsupported system: install a C compiler, make, cmake, git, pkg-config and" \
             "the OpenSSL development headers, then rerun with --no-deps." >&2
        exit 1
    fi
}

echo "==> [1/3] Dependencies"
if [ "$WITH_DEPS" = "1" ]; then install_deps; else echo "skipped (--no-deps)"; fi

echo "==> [2/3] Build picoquic"
"$ROOT/common/build_picoquic.sh" "$PREFIX"

echo "==> [3/3] Verify"
BIN="$PREFIX/picoquicdemo"
[ -x "$BIN" ] || { echo "ERROR: $BIN was not produced." >&2; exit 1; }
HELP="$("$BIN" -h 2>&1 || true)"
if ! grep -q -- "-M" <<<"$HELP"; then
    echo "ERROR: $BIN does not list the multipath option -M." >&2
    exit 1
fi
if ! grep -q "MPSTAT" "$ROOT/third_party/picoquic/picoquicfirst/picoquicdemo.c"; then
    echo "ERROR: the MPSTAT patch is not present in the built sources." >&2
    exit 1
fi
echo "OK: $BIN"
echo "    $(grep -m1 -o 'Picoquic (v[^)]*)' <<<"$HELP" || echo 'picoquic') with multipath (-M) and MPSTAT per-path statistics"

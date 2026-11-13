#!/usr/bin/env bash
# Build the client binary into <repo>/bin.
#   Ubuntu/Debian : sudo apt-get install -y build-essential cmake git pkg-config libssl-dev
#   macOS         : brew install cmake pkg-config openssl@3
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/common/build_picoquic.sh" "$ROOT/bin"

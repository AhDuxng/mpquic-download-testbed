#!/usr/bin/env bash
# Install build dependencies on the server (Ubuntu/Debian or Amazon Linux/RHEL).
set -euo pipefail

if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y build-essential cmake git pkg-config libssl-dev openssl
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y gcc gcc-c++ make cmake git pkgconf-pkg-config openssl-devel openssl
else
    echo "Unsupported distro: install gcc, cmake, git, pkg-config, OpenSSL dev headers manually." >&2
    exit 1
fi
echo "Dependencies installed."

#!/usr/bin/env bash
# =============================================================================
# File        : server/gen_testfiles.sh
# Project     : mpquic-download-testbed
# Description : Generates the files served to the client. Content comes from
#               /dev/urandom, so it is incompressible and every byte has to cross
#               the network. Files that already have the requested size are kept.
#
# Usage       : server/gen_testfiles.sh
# Input       : TEST_FILES in config.env, e.g. "file_10MB.bin:10M" (suffix K, M, G).
# Output      : SERVER_INSTALL_DIR/www/  test files, SHA256SUMS (lets the client
#               prove every download is complete and intact) and index.html.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
W="$SERVER_INSTALL_DIR/www"
mkdir -p "$W"
cd "$W"

to_bytes() {
    local v="$1" n="${1%[KMGkmg]}"
    case "$v" in
        *[Kk]) echo $((n * 1024)) ;;
        *[Mm]) echo $((n * 1024 * 1024)) ;;
        *[Gg]) echo $((n * 1024 * 1024 * 1024)) ;;
        *) echo "$n" ;;
    esac
}

for spec in $TEST_FILES; do
    name="${spec%%:*}"; size="$(to_bytes "${spec##*:}")"
    if [ -f "$name" ] && [ "$(stat -c %s "$name" 2>/dev/null || stat -f %z "$name")" = "$size" ]; then
        echo "keep $name"
        continue
    fi
    echo "gen  $name ($size bytes)"
    head -c "$size" /dev/urandom > "$name"
done

sha256sum file_*.bin > SHA256SUMS 2>/dev/null || shasum -a 256 file_*.bin > SHA256SUMS

{
    echo "<!doctype html><html><head><meta charset=utf-8><title>MPQUIC test server</title></head><body>"
    echo "<h1>MPQUIC test server</h1><p>picoquic $PICOQUIC_COMMIT, HTTP/3 over QUIC multipath.</p><ul>"
    for f in file_*.bin SHA256SUMS; do echo "<li><a href=\"/$f\">$f</a></li>"; done
    echo "</ul></body></html>"
} > index.html

ls -l "$W"

#!/usr/bin/env bash
# Generate random (incompressible) test files + SHA256SUMS + index.html in www/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
W="$SERVER_INSTALL_DIR/www"
mkdir -p "$W"
cd "$W"

to_bytes() {  # 10M -> 10485760
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

# Checksums let the client prove each download is complete and intact.
sha256sum file_*.bin > SHA256SUMS 2>/dev/null || shasum -a 256 file_*.bin > SHA256SUMS

{
    echo "<!doctype html><html><head><meta charset=utf-8><title>MPQUIC test server</title></head><body>"
    echo "<h1>MPQUIC test server</h1><p>picoquic $PICOQUIC_COMMIT, HTTP/3 over QUIC multipath.</p><ul>"
    for f in file_*.bin SHA256SUMS; do echo "<li><a href=\"/$f\">$f</a></li>"; done
    echo "</ul></body></html>"
} > index.html

ls -l "$W"

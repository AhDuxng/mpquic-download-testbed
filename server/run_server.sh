#!/usr/bin/env bash
# Start the MPQUIC HTTP/3 file server (foreground; systemd runs this).
#   -M  : advertise QUIC multipath (initial_max_path_id = 2 -> up to 3 paths)
#   -w  : web root,  -c/-k : cert/key,  -p : UDP port
# Optional: QLOG=1 to write qlog per connection into qlog/ (large for big files).
set -euo pipefail

D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$D/config.env"

ARGS=(-M -p "$SERVER_PORT" -w "$D/www" -c "$D/certs/cert.pem" -k "$D/certs/key.pem")
# Optional: SO_BUF=4194304 to request bigger UDP socket buffers (-B)
[ -n "${SO_BUF:-}" ] && ARGS+=(-B "$SO_BUF")
if [ "${QLOG:-0}" = "1" ]; then
    mkdir -p "$D/qlog"
    ARGS+=(-q "$D/qlog")
fi

cd "$D/logs"   # picoquicdemo writes ticket/token stores in the cwd
exec "$D/bin/picoquicdemo" "${ARGS[@]}"

#!/usr/bin/env bash
# =============================================================================
# File        : server/run_server.sh
# Project     : mpquic-download-testbed
# Description : Runs the HTTP/3 file server in the foreground. Installed into
#               SERVER_INSTALL_DIR by setup_server.sh and executed from there by
#               systemd (mpquic-server.service) or by start_server.sh.
#
# picoquic    : -M            advertise QUIC multipath (initial_max_path_id = 2,
#                             i.e. up to 3 paths per connection)
#               -p PORT       UDP port            -w DIR   web root
#               -c/-k FILE    certificate / key   -q DIR   qlog output
#               -B BYTES      UDP socket buffer size
#
# Environment : QLOG=1        write one qlog per connection to qlog/ (large for
#                             big files; enable only for debugging)
#               SO_BUF=BYTES  request larger UDP socket buffers, e.g. 4194304
# Working dir : logs/, where picoquicdemo writes its ticket and token stores.
# =============================================================================
set -euo pipefail

D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$D/config.env"

ARGS=(-M -p "$SERVER_PORT" -w "$D/www" -c "$D/certs/cert.pem" -k "$D/certs/key.pem")
[ -n "${SO_BUF:-}" ] && ARGS+=(-B "$SO_BUF")
if [ "${QLOG:-0}" = "1" ]; then
    mkdir -p "$D/qlog"
    ARGS+=(-q "$D/qlog")
fi

cd "$D/logs"
exec "$D/bin/picoquicdemo" "${ARGS[@]}"

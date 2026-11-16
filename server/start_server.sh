#!/usr/bin/env bash
# =============================================================================
# File        : server/start_server.sh
# Project     : mpquic-download-testbed
# Description : Starts or stops the HTTP/3 server in the background without
#               systemd, for hosts set up with `setup_server.sh --no-service`.
#               The process is detached from the terminal (setsid + nohup), so
#               it survives the end of the SSH session but not a reboot.
#
# Usage       : server/start_server.sh            start (QLOG=1 to enable qlog)
#               server/start_server.sh --stop     stop
#               server/start_server.sh --status   show process and UDP socket
#
# Files       : SERVER_INSTALL_DIR/server.pid   process id
#               SERVER_INSTALL_DIR/server.log   stdout and stderr
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
D="$SERVER_INSTALL_DIR"
PIDFILE="$D/server.pid"

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-}" in
    --stop)
        if running; then
            kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE" && echo "Stopped."
        else
            echo "Not running."
        fi
        ;;
    --status)
        if running; then
            echo "Running, pid $(cat "$PIDFILE")"
            ss -ulpn 2>/dev/null | grep ":$SERVER_PORT " || true
        else
            echo "Not running."
        fi
        ;;
    "")
        [ -x "$D/run_server.sh" ] || { echo "Run server/setup_server.sh first." >&2; exit 1; }
        running && { echo "Already running, pid $(cat "$PIDFILE")."; exit 0; }
        setsid nohup "$D/run_server.sh" >"$D/server.log" 2>&1 </dev/null &
        echo $! >"$PIDFILE"
        sleep 1
        running || { echo "Server exited; see $D/server.log" >&2; exit 1; }
        echo "Started, pid $(cat "$PIDFILE"), udp/$SERVER_PORT, log $D/server.log"
        ;;
    *)
        echo "usage: $0 [--stop|--status]" >&2; exit 1 ;;
esac

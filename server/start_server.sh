#!/usr/bin/env bash
# =============================================================================
# File        : server/start_server.sh
# Project     : mpquic-download-testbed
# Description : Starts, stops or inspects the file servers in the background
#               without systemd, for hosts set up with
#               `setup_server.sh --no-service`. Each process is detached from
#               the terminal (setsid + nohup): it survives the end of the SSH
#               session but not a reboot.
#
# Usage       : server/start_server.sh [--stop|--status] [mpquic|mptcp|all]
#               The target defaults to all.
# Examples    : server/start_server.sh                 start both servers
#               server/start_server.sh --status        show both
#               server/start_server.sh --stop mptcp    stop the MPTCP server
#               QLOG=1 server/start_server.sh mpquic   MPQUIC server with qlog
#
# Servers     : mpquic  run_mpquic_server.sh  HTTP/3 on UDP SERVER_PORT
#               mptcp   run_mptcp_server.sh   HTTPS on TCP MPTCP_PORT
# Files       : SERVER_INSTALL_DIR/<name>.pid and <name>.log
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
D="$SERVER_INSTALL_DIR"

ACTION=start
TARGET=all
for arg in "$@"; do
    case "$arg" in
        --stop)   ACTION=stop ;;
        --status) ACTION=status ;;
        mpquic|mptcp|all) TARGET="$arg" ;;
        *) echo "usage: $0 [--stop|--status] [mpquic|mptcp|all]" >&2; exit 1 ;;
    esac
done
[ "$TARGET" = "all" ] && NAMES=(mpquic mptcp) || NAMES=("$TARGET")

pidfile() { echo "$D/$1.pid"; }
running() { [ -f "$(pidfile "$1")" ] && kill -0 "$(cat "$(pidfile "$1")")" 2>/dev/null; }
port_of() { [ "$1" = "mpquic" ] && echo "udp/$SERVER_PORT" || echo "tcp/$MPTCP_PORT"; }

for name in "${NAMES[@]}"; do
    case "$ACTION" in
    start)
        script="$D/run_${name}_server.sh"
        [ -x "$script" ] || { echo "$name: $script missing, run server/setup_server.sh first." >&2; exit 1; }
        if running "$name"; then
            echo "$name: already running, pid $(cat "$(pidfile "$name")")"
            continue
        fi
        setsid nohup "$script" >"$D/$name.log" 2>&1 </dev/null &
        echo $! >"$(pidfile "$name")"
        sleep 1
        running "$name" || { echo "$name: exited, see $D/$name.log" >&2; exit 1; }
        echo "$name: started, pid $(cat "$(pidfile "$name")"), $(port_of "$name"), log $D/$name.log"
        ;;
    stop)
        if running "$name"; then
            kill "$(cat "$(pidfile "$name")")" && rm -f "$(pidfile "$name")" && echo "$name: stopped"
        else
            echo "$name: not running"
        fi
        ;;
    status)
        if running "$name"; then
            echo "$name: running, pid $(cat "$(pidfile "$name")"), $(port_of "$name")"
        else
            echo "$name: not running"
        fi
        ;;
    esac
done

#!/usr/bin/env bash
# Single download, for manual testing.
#
#   client/download.sh <mode> <file> [outdir]
#
# mode:
#   sp      single path (no multipath extension)
#   mp-sim  multipath, 2nd path = same interface, different UDP port
#           (works on any machine; checks the protocol, gives no bandwidth gain)
#   mp      multipath over real interfaces; set ALT_PATHS, e.g.
#           ALT_PATHS="192.168.43.100/4"   (client_ip/ifindex of 2nd interface)
#           Linux: ifindex from `ip -o link`. Several: "ip1/if1,ip2/if2".
#
# Env: PRIMARY_IF=<ifindex>  force path 0 onto one interface (-e)
#      QLOG=1                write qlog into <outdir>/qlog (view at qvis.quictools.info)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
BIN="$ROOT/bin/picoquicdemo"

MODE="${1:?mode: sp|mp-sim|mp}"
FILE="${2:?file, e.g. file_10MB.bin}"
DEFAULT_OUT="$ROOT/downloads"
[ -d /dev/shm ] && DEFAULT_OUT="$CLIENT_DL_DIR"   # RAM, avoids SD-card bottleneck on the Pi
OUT="$(mkdir -p "${3:-$DEFAULT_OUT}" && cd "${3:-$DEFAULT_OUT}" && pwd)"

[ -x "$BIN" ] || { echo "Build first: common/build_picoquic.sh" >&2; exit 1; }

ARGS=(-n "$SERVER_SNI" -o "$OUT")
[ -n "${CLIENT_CIPHER:-}" ] && ARGS+=(-C "$CLIENT_CIPHER")
case "$MODE" in
    sp)     ;;
    mp-sim) ARGS+=(-M -A 0.0.0.0/0) ;;
    mp)     ARGS+=(-M -A "${ALT_PATHS:?set ALT_PATHS=client_ip/ifindex}") ;;
    *)      echo "unknown mode $MODE" >&2; exit 1 ;;
esac
[ -n "${PRIMARY_IF:-}" ] && ARGS+=(-e "$PRIMARY_IF")
[ "${QLOG:-0}" = "1" ] && { mkdir -p "$OUT/qlog"; ARGS+=(-q "$OUT/qlog"); }

# Fresh cwd each run: no stored session ticket -> full handshake, no 0-RTT bias.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

"$BIN" "${ARGS[@]}" "$SERVER_IP" "$SERVER_PORT" "/$FILE" | tee "$OUT/last_run.log" \
    | grep -E "Negotiated ALPN|Enable multipath|Received [0-9]+ bytes|MPSTAT|error|Cannot" || true
ls -l "$OUT/$FILE"

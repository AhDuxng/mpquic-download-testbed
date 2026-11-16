#!/usr/bin/env bash
# =============================================================================
# File        : client/mpquic/download.sh
# Project     : mpquic-download-testbed
# Description : Downloads one file once over multipath QUIC, for setup checks
#               and smoke tests, and prints the lines that show whether
#               multipath was negotiated and whether every path carried data.
#
# Usage       : ALT_PATHS="<ip>/<ifindex>" client/mpquic/download.sh <file> [outdir]
# Example     : ALT_PATHS="10.50.40.68/3" client/mpquic/download.sh file_10MB.bin
#
# Environment : ALT_PATHS   required; local address and interface index of each
#                           additional path, comma separated
#                           ("ip1/if1,ip2/if2"); ifindex from `ip -o link`
#               PRIMARY_IF  optional; pins path 0 to one interface (picoquic -e)
#               QLOG=1      optional; writes qlog to <outdir>/qlog
#
# Success     : "Enable multipath: Success", one "MPSTAT path=N" line per path,
#               and bytes_received > 0 on every path.
#
# Output      : <outdir>/<file> and <outdir>/last_run.log. The default outdir is
#               CLIENT_DL_DIR (RAM) when /dev/shm exists, else <repo>/downloads.
#               Each run uses an empty working directory, so no session ticket is
#               reused: full handshake every time, no 0-RTT.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../config.env
source "$ROOT/config.env"
BIN="$ROOT/bin/picoquicdemo"

FILE="${1:?usage: ALT_PATHS=<ip>/<ifindex> $0 <file> [outdir]}"
ALT="${ALT_PATHS:?set ALT_PATHS=<client_ip>/<ifindex> of the second interface (see README)}"
DEFAULT_OUT="$ROOT/downloads"
[ -d /dev/shm ] && DEFAULT_OUT="$CLIENT_DL_DIR"
OUT="$(mkdir -p "${2:-$DEFAULT_OUT}" && cd "${2:-$DEFAULT_OUT}" && pwd)"

[ -x "$BIN" ] || { echo "Build first: ./install_picoquic.sh" >&2; exit 1; }

ARGS=(-n "$SERVER_SNI" -o "$OUT" -M -A "$ALT")
[ -n "${CLIENT_CIPHER:-}" ] && ARGS+=(-C "$CLIENT_CIPHER")
[ -n "${PRIMARY_IF:-}" ] && ARGS+=(-e "$PRIMARY_IF")
[ "${QLOG:-0}" = "1" ] && { mkdir -p "$OUT/qlog"; ARGS+=(-q "$OUT/qlog"); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

"$BIN" "${ARGS[@]}" "$SERVER_IP" "$SERVER_PORT" "/$FILE" | tee "$OUT/last_run.log" \
    | grep -E "Negotiated ALPN|Enable multipath|Received [0-9]+ bytes|MPSTAT|error|Cannot" || true
ls -l "$OUT/$FILE"

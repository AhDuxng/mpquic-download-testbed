#!/usr/bin/env bash
# =============================================================================
# File        : client/mptcp/download.sh
# Project     : mpquic-download-testbed
# Description : Downloads one file once over MPTCP (HTTPS, TLS 1.3) with curl,
#               for setup checks and smoke tests, and shows whether MPTCP was
#               negotiated and how many extra subflows were established.
#
# Usage       : client/mptcp/download.sh <file> [outdir]
# Example     : client/mptcp/download.sh file_10MB.bin
#
# Requires    : curl >= 8.9 with --mptcp (or mptcpize from the mptcpd package),
#               endpoints configured with client/mptcp/setup_mptcp.sh.
#
# Success     : MPCapableSYNACKRX = 1 (MPTCP negotiated, no fallback to TCP),
#               MPJoinSynAckRx >= 1 (an extra subflow joined), and received
#               bytes on every path interface.
#
# TLS         : TLS 1.3 only; the cipher follows CLIENT_CIPHER (20 = ChaCha20,
#               128 = AES-128-GCM, 256 = AES-256-GCM), as for the MPQUIC client.
#               The self-signed certificate is accepted (-k) and SNI is
#               SERVER_SNI, as for picoquicdemo. Each run is a new process, so
#               no TLS session is resumed.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../config.env
source "$ROOT/config.env"

FILE="${1:?usage: $0 <file> [outdir]}"
DEFAULT_OUT="$ROOT/downloads"
[ -d /dev/shm ] && DEFAULT_OUT="$CLIENT_DL_DIR"
OUT="$(mkdir -p "${2:-$DEFAULT_OUT}" && cd "${2:-$DEFAULT_OUT}" && pwd)"

if curl --help all 2>/dev/null | grep -q -- "--mptcp"; then
    CURL=(curl --mptcp)
elif command -v mptcpize >/dev/null 2>&1; then
    CURL=(mptcpize run curl)
else
    echo "curl has no --mptcp and mptcpize is missing (apt-get install mptcpd)" >&2; exit 1
fi

case "${CLIENT_CIPHER:-}" in
    20)  TLS13=(--tls13-ciphers TLS_CHACHA20_POLY1305_SHA256) ;;
    128) TLS13=(--tls13-ciphers TLS_AES_128_GCM_SHA256) ;;
    256) TLS13=(--tls13-ciphers TLS_AES_256_GCM_SHA384) ;;
    *)   TLS13=() ;;
esac

mib() { awk '/^MPTcpExt:/ { if (!h) { for (i = 2; i <= NF; i++) k[i] = $i; h = 1 }
                            else    { for (i = 2; i <= NF; i++) print k[i], $i } }' /proc/net/netstat; }
get() { awk -v n="$1" '$1 == n { v = $2 } END { print v + 0 }' <<<"$2"; }

BEFORE="$(mib)"
"${CURL[@]}" -k -sS -f --tlsv1.3 "${TLS13[@]}" --http1.1 \
    --resolve "$SERVER_SNI:$MPTCP_PORT:$SERVER_IP" \
    -o "$OUT/$FILE" \
    -w "http=%{http_code} size=%{size_download} connect=%{time_connect}s tls=%{time_appconnect}s first_byte=%{time_starttransfer}s total=%{time_total}s speed=%{speed_download}B/s local=%{local_ip}\n" \
    "https://$SERVER_SNI:$MPTCP_PORT/$FILE" | tee "$OUT/last_run_mptcp.log"
AFTER="$(mib)"

for c in MPCapableSYNTX MPCapableSYNACKRX MPCapableFallbackSYNACK MPJoinSynAckRx; do
    echo "$c=$(( $(get "$c" "$AFTER") - $(get "$c" "$BEFORE") ))"
done | tee -a "$OUT/last_run_mptcp.log"
ls -l "$OUT/$FILE"

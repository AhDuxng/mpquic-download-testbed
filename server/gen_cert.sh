#!/usr/bin/env bash
# =============================================================================
# File        : server/gen_cert.sh
# Project     : mpquic-download-testbed
# Description : Creates a self-signed ECDSA P-256 certificate for the server, with
#               SERVER_SNI and SERVER_IP in the subjectAltName. picoquicdemo does
#               not verify the certificate chain as a client unless -t is given,
#               so a self-signed certificate is sufficient for the experiment.
#
# Usage       : server/gen_cert.sh
# Output      : SERVER_INSTALL_DIR/certs/{cert.pem,key.pem}; an existing pair is
#               kept (delete it to regenerate).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
C="$SERVER_INSTALL_DIR/certs"
mkdir -p "$C"

if [ -f "$C/cert.pem" ] && [ -f "$C/key.pem" ]; then
    echo "Cert already exists in $C (delete it to regenerate)."
    exit 0
fi

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$C/key.pem" -out "$C/cert.pem" -days 825 \
    -subj "/CN=$SERVER_SNI" \
    -addext "subjectAltName=DNS:$SERVER_SNI,IP:$SERVER_IP"
chmod 600 "$C/key.pem"
echo "Cert written to $C"

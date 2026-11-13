#!/usr/bin/env bash
# Self-signed certificate for the server (IP + SNI name in SAN).
# picoquicdemo as a client does not verify the chain unless -t is given,
# so a self-signed cert is enough for the experiment.
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

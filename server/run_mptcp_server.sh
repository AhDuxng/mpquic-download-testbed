#!/usr/bin/env bash
# =============================================================================
# File        : server/run_mptcp_server.sh
# Project     : mpquic-download-testbed
# Description : Runs the HTTPS (MPTCP) file server in the foreground. Installed
#               into SERVER_INSTALL_DIR by setup_server.sh and run from there by
#               systemd (mptcp-server.service) or start_server.sh.
#
# Server      : mptcp_https_server.py on TCP MPTCP_PORT, same www/ directory,
#               certificate and congestion control as the MPQUIC server.
# Requires    : net.mptcp.enabled = 1 (default on recent Ubuntu kernels).
# =============================================================================
set -euo pipefail

D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$D/config.env"

exec python3 "$D/mptcp_https_server.py" --www "$D/www" --port "$MPTCP_PORT" \
    --cert "$D/certs/cert.pem" --key "$D/certs/key.pem" --cc "${CONGESTION_CONTROL:-cubic}"

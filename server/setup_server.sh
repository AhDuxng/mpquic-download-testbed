#!/usr/bin/env bash
# =============================================================================
# File        : server/setup_server.sh
# Project     : mpquic-download-testbed
# Description : One-shot server setup, run ON THE SERVER from the repository
#               root. Installs both file servers, which serve the same www/:
#                 MPQUIC  picoquicdemo -M, HTTP/3 on UDP SERVER_PORT
#                 MPTCP   mptcp_https_server.py, HTTPS on TCP MPTCP_PORT
#               Everything needed at run time is placed in SERVER_INSTALL_DIR.
#
# Usage       : server/setup_server.sh                full setup, systemd service
#               server/setup_server.sh --no-service   no system changes beyond
#                                                     packages; start manually
#                                                     with server/start_server.sh
#
# Steps       : 1-2. Install dependencies and build picoquicdemo into
#                    SERVER_INSTALL_DIR/bin (install_picoquic.sh).
#               3. Create a self-signed certificate (server/gen_cert.sh).
#               4. Generate test files, SHA256SUMS, index.html (gen_testfiles.sh).
#               5. Copy the run scripts, the MPTCP server and config.env
#                  next to the binaries.
#               Full setup only:
#               6. Raise UDP socket buffer limits (/etc/sysctl.d/90-mpquic.conf).
#               7. Install and start the systemd units mpquic-server and
#                  mptcp-server.
#               8. Open both ports in ufw when ufw is active.
#
# Note        : The AWS Security Group must also allow inbound UDP SERVER_PORT
#               and TCP MPTCP_PORT.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
D="$SERVER_INSTALL_DIR"

WITH_SERVICE=1
case "${1:-}" in
    --no-service) WITH_SERVICE=0 ;;
    "")           ;;
    *)            echo "usage: $0 [--no-service]" >&2; exit 1 ;;
esac

sudo mkdir -p "$D"/{bin,certs,www,logs,qlog}
sudo chown -R "$(id -u):$(id -g)" "$D"

"$ROOT/install_picoquic.sh" --prefix "$D/bin"
"$ROOT/server/gen_cert.sh"
"$ROOT/server/gen_testfiles.sh"

cp "$ROOT/server/run_mpquic_server.sh" "$ROOT/server/run_mptcp_server.sh" \
   "$ROOT/server/mptcp_https_server.py" "$ROOT/config.env" "$D/"
chmod +x "$D/run_mpquic_server.sh" "$D/run_mptcp_server.sh"

if [ "$WITH_SERVICE" = "0" ]; then
    echo
    echo "Installed in $D (no systemd service)."
    echo "Start: $ROOT/server/start_server.sh    Stop: $ROOT/server/start_server.sh --stop"
    exit 0
fi

sudo tee /etc/sysctl.d/90-mpquic.conf >/dev/null <<'EOF'
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
EOF
sudo sysctl --system >/dev/null

sudo sysctl -qw net.mptcp.enabled=1
for unit in mpquic-server mptcp-server; do
    sed -e "s#@USER@#$(id -un)#g" -e "s#@DIR@#$D#g" "$ROOT/server/$unit.service" \
        | sudo tee "/etc/systemd/system/$unit.service" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now mpquic-server mptcp-server
sleep 1
sudo systemctl --no-pager status mpquic-server mptcp-server | grep -E "●|Active:"

if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow "$SERVER_PORT"/udp
    sudo ufw allow "$MPTCP_PORT"/tcp
fi

echo
echo "MPQUIC: udp://$SERVER_IP:$SERVER_PORT   MPTCP: tcp://$SERVER_IP:$MPTCP_PORT   (files in $D/www)"
echo "Reminder: AWS Security Group inbound: UDP $SERVER_PORT and TCP $MPTCP_PORT."

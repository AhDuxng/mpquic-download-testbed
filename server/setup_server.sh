#!/usr/bin/env bash
# =============================================================================
# File        : server/setup_server.sh
# Project     : mpquic-download-testbed
# Description : One-shot server setup, run ON THE SERVER from the repository
#               root. Everything the server needs at run time is placed in
#               SERVER_INSTALL_DIR (config.env).
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
#               5. Copy run_server.sh and config.env next to the binaries.
#               Full setup only:
#               6. Raise UDP socket buffer limits (/etc/sysctl.d/90-mpquic.conf).
#               7. Install and start the systemd unit mpquic-server.
#               8. Open the UDP port in ufw when ufw is active.
#
# Note        : The AWS Security Group must also allow inbound UDP SERVER_PORT.
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

cp "$ROOT/server/run_server.sh" "$ROOT/config.env" "$D/"
chmod +x "$D/run_server.sh"

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

sed -e "s#@USER@#$(id -un)#g" -e "s#@DIR@#$D#g" "$ROOT/server/mpquic-server.service" \
    | sudo tee /etc/systemd/system/mpquic-server.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now mpquic-server
sleep 1
sudo systemctl --no-pager status mpquic-server | head -n 12

if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow "$SERVER_PORT"/udp
fi

echo
echo "Server ready: udp://$SERVER_IP:$SERVER_PORT  (files in $D/www)"
echo "Reminder: AWS Console -> EC2 -> Security Group -> Inbound: Custom UDP, port $SERVER_PORT."

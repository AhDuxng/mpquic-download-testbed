#!/usr/bin/env bash
# One-shot server setup. Run ON THE SERVER from the repo root:
#   sudo -v && ./server/setup_server.sh
#
# Does: install deps -> build picoquicdemo -> self-signed cert -> test files
#       -> systemd service (mpquic-server) started and enabled.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"
D="$SERVER_INSTALL_DIR"

"$ROOT/server/install_deps.sh"

sudo mkdir -p "$D"/{bin,certs,www,logs,qlog}
sudo chown -R "$(id -u):$(id -g)" "$D"

"$ROOT/common/build_picoquic.sh" "$D/bin"
"$ROOT/server/gen_cert.sh"
"$ROOT/server/gen_testfiles.sh"

cp "$ROOT/server/run_server.sh" "$ROOT/config.env" "$D/"
chmod +x "$D/run_server.sh"

# Larger UDP socket buffers so the kernel does not drop bursts at high rates
sudo tee /etc/sysctl.d/90-mpquic.conf >/dev/null <<'EOF'
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
EOF
sudo sysctl --system >/dev/null

# systemd unit, rendered with the current user and install dir
sed -e "s#@USER@#$(id -un)#g" -e "s#@DIR@#$D#g" "$ROOT/server/mpquic-server.service" \
    | sudo tee /etc/systemd/system/mpquic-server.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now mpquic-server
sleep 1
sudo systemctl --no-pager status mpquic-server | head -n 12

# Host firewall (the AWS Security Group must ALSO allow UDP $SERVER_PORT)
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow "$SERVER_PORT"/udp
fi

echo
echo "Server ready: udp://$SERVER_IP:$SERVER_PORT  (files in $D/www)"
echo "Reminder: AWS Console -> EC2 -> Security Group -> Inbound: Custom UDP, port $SERVER_PORT, source <your client IPs>."

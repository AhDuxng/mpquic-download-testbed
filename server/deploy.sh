#!/usr/bin/env bash
# Run FROM YOUR LAPTOP: copy this repo to the server, then run setup there.
#   ./server/deploy.sh          # copy + setup
#   ./server/deploy.sh --copy   # copy only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"

SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_IP")

rsync -az --delete -e "ssh -i $SSH_KEY" \
    --exclude third_party --exclude bin --exclude results --exclude .git \
    "$ROOT/" "$SSH_USER@$SERVER_IP:~/mpquic-download-testbed/"

if [ "${1:-}" != "--copy" ]; then
    "${SSH[@]}" "cd ~/mpquic-download-testbed && chmod +x server/*.sh common/*.sh && ./server/setup_server.sh"
fi

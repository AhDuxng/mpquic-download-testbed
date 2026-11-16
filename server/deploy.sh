#!/usr/bin/env bash
# =============================================================================
# File        : server/deploy.sh
# Project     : mpquic-download-testbed
# Description : Run from a workstation. Copies this repository to the server
#               (REMOTE_REPO_DIR) over SSH and optionally runs the setup there.
#
# Usage       : server/deploy.sh                 copy, then full setup (systemd)
#               server/deploy.sh --no-service    copy, then setup without systemd
#               server/deploy.sh --copy          copy only
#
# Requires    : SSH_USER, SSH_KEY and REMOTE_REPO_DIR set in config.env; rsync on
#               both hosts; passwordless sudo for SSH_USER on the server (the
#               parent of REMOTE_REPO_DIR may be owned by root).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"

MODE="${1:-}"
REMOTE="$SSH_USER@$SERVER_IP"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$REMOTE")

"${SSH[@]}" "sudo mkdir -p '$REMOTE_REPO_DIR' && sudo chown \"\$(id -u):\$(id -g)\" '$REMOTE_REPO_DIR'"

rsync -az --delete -e "ssh -i $SSH_KEY" \
    --exclude third_party --exclude bin --exclude results --exclude run \
    --exclude .git --exclude build.log \
    "$ROOT/" "$REMOTE:$REMOTE_REPO_DIR/"

case "$MODE" in
    --copy)       exit 0 ;;
    --no-service) SETUP_ARGS="--no-service" ;;
    "")           SETUP_ARGS="" ;;
    *)            echo "usage: $0 [--copy|--no-service]" >&2; exit 1 ;;
esac

"${SSH[@]}" "cd '$REMOTE_REPO_DIR' && chmod +x server/*.sh common/*.sh client/*.sh && ./server/setup_server.sh $SETUP_ARGS"

#!/usr/bin/env bash
# cli/templates/devcontainer/sandcat/scripts/proxy-peer-init.sh
set -euo pipefail

NB_SETUP_KEY="${NB_SETUP_KEY:?NB_SETUP_KEY is required}"
NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-}"
HELLO_PORT="${PROXY_PEER_PORT:-8080}"

if [[ -n "$NB_MANAGEMENT_URL" ]]; then
  export NB_MANAGEMENT_URL
fi

netbird up --setup-key "$NB_SETUP_KEY"

exec python3 /usr/local/bin/proxy-peer-hello.py --port "$HELLO_PORT"

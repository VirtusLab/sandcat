#!/usr/bin/env bash
# docs/examples/proxy-peer/scripts/proxy-peer-init.sh
set -euo pipefail

NB_SETUP_KEY="${NB_SETUP_KEY:?NB_SETUP_KEY is required}"
NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-}"
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
HELLO_PORT="${PROXY_PEER_PORT:-8080}"
# DNS label used for both `netbird up --hostname` and the post-enrollment
# PATCH /api/peers/{id}.
NB_PEER_NAME="${NB_PEER_NAME:?NB_PEER_NAME must be set by compose}"
NETBIRD_PEER_LOG_PREFIX="${NETBIRD_PEER_LOG_PREFIX:-proxy-peer}"
NETBIRD_PEER_LIFECYCLE_PATH="${NETBIRD_PEER_LIFECYCLE_PATH:-/usr/local/lib/netbird-peer-lifecycle.sh}"

# shellcheck source=/usr/local/lib/netbird-peer-lifecycle.sh
source "$NETBIRD_PEER_LIFECYCLE_PATH"

netbird_start "${NETBIRD_IFACE}"
netbird_set_dns_label
netbird_supervise_daemon "${NETBIRD_IFACE}" &

exec python3 /usr/local/bin/proxy-peer-hello.py --port "$HELLO_PORT"

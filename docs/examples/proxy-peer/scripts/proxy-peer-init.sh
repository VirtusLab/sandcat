#!/usr/bin/env bash
# docs/examples/proxy-peer/scripts/proxy-peer-init.sh
set -euo pipefail

NB_SETUP_KEY="${NB_SETUP_KEY:?NB_SETUP_KEY is required}"
NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-}"
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
HELLO_PORT="${PROXY_PEER_PORT:-8080}"
# DNS label used for both `netbird up --hostname` and the post-enrollment
# PATCH /api/peers/{id}. Must match capability-catalog.json dns_label prefix.
NB_PEER_NAME="${NB_PEER_NAME:?NB_PEER_NAME must be set by compose}"
NETBIRD_PEER_LOG_PREFIX="${NETBIRD_PEER_LOG_PREFIX:-proxy-peer}"
NETBIRD_PEER_LIFECYCLE_PATH="${NETBIRD_PEER_LIFECYCLE_PATH:-/usr/local/lib/netbird-peer-lifecycle.sh}"

# shellcheck source=/usr/local/lib/netbird-peer-lifecycle.sh
source "$NETBIRD_PEER_LIFECYCLE_PATH"

wait_until() {
    local max="$1" delay="$2" msg="$3"
    shift 3
    local attempt=0
    while ! "$@"; do
        if [[ "$attempt" -ge "$max" ]]; then
            echo "$msg" >&2
            return 1
        fi
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

netbird_management_url_host() {
    local url=$1
    [[ "$url" =~ ^https?://([^/:]+) ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

netbird_management_url_host_is_literal_ipv4() {
    local host=$1
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

netbird_management_url_port() {
    local url=$1
    if [[ "$url" =~ :([0-9]+)(/|$|\?) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$url" =~ ^https:// ]]; then
        printf '443'
    else
        printf '80'
    fi
}

netbird_host_route_uses_gateway() {
    local host_ip=$1
    local docker_gateway=$2
    [[ -n "$host_ip" && -n "$docker_gateway" ]] || return 1
    [[ "$host_ip" != "$docker_gateway" ]]
}

# Self-hosted management on the Docker host must use eth0 (not the mesh iface).
configure_netbird_host_management_access() {
    local docker_gateway=$1
    local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
    local host_ip port

    [[ -n "$docker_gateway" ]] || return 0

    host_ip=$(netbird_management_url_host "$mgmt_url") || return 0
    netbird_management_url_host_is_literal_ipv4 "$host_ip" || return 0

    port=$(netbird_management_url_port "$mgmt_url")

    if netbird_host_route_uses_gateway "$host_ip" "$docker_gateway"; then
        echo "[proxy-peer] Allowing NetBird management traffic to ${host_ip}:${port} via eth0 (via ${docker_gateway})." >&2
    else
        echo "[proxy-peer] Allowing NetBird management traffic to ${host_ip}:${port} via eth0." >&2
    fi

    ip -4 rule add to "${host_ip}/32" lookup main priority 50 2>/dev/null || true
    if netbird_host_route_uses_gateway "$host_ip" "$docker_gateway"; then
        ip -4 route add "${host_ip}/32" via "${docker_gateway}" dev eth0 2>/dev/null || true
    else
        ip -4 route add "${host_ip}/32" dev eth0 2>/dev/null || true
    fi

    iptables -C OUTPUT -o eth0 -d "$host_ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I OUTPUT 1 -o eth0 -d "$host_ip" -p tcp --dport "$port" -j ACCEPT
    iptables -C OUTPUT -o eth0 -d "$host_ip" -p udp --dport 3478 -j ACCEPT 2>/dev/null \
        || iptables -I OUTPUT 1 -o eth0 -d "$host_ip" -p udp --dport 3478 -j ACCEPT
}

netbird_verify_host_management_reachable() {
    local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
    local host_ip port check_url

    host_ip=$(netbird_management_url_host "$mgmt_url") || return 0
    netbird_management_url_host_is_literal_ipv4 "$host_ip" || return 0

    port=$(netbird_management_url_port "$mgmt_url")
    command -v curl >/dev/null 2>&1 || return 0

    check_url="${mgmt_url%/}/api/instance"
    wait_until 15 1 \
        "[proxy-peer] Cannot reach NetBird management at ${mgmt_url}; is netbird-server running on the host (port ${port})?" \
        curl -sf --max-time 5 "$check_url" >/dev/null
}

netbird_export_service_env() {
    local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
    export NB_MANAGEMENT_URL="$mgmt_url"
    if netbird_management_url_host_is_literal_ipv4 "$(netbird_management_url_host "$mgmt_url" 2>/dev/null)"; then
        export NB_USE_LEGACY_ROUTING=true
    fi
}

netbird_daemon_ready() {
    netbird status >/dev/null 2>&1
}

ensure_netbird_service() {
    netbird_prepare_local_management_profile
    netbird_export_service_env
    if netbird_daemon_ready; then
        return 0
    fi

    echo "[proxy-peer] Starting NetBird service daemon ($(netbird version 2>/dev/null || echo unknown))." >&2
    netbird service run --log-file console &

    wait_until 30 1 \
        "[proxy-peer] Timed out waiting for NetBird service daemon" \
        netbird_daemon_ready
}

start_netbird() {
    local iface="${1:-wt0}"
    local docker_gateway

    docker_gateway=$(ip -4 route show default dev eth0 2>/dev/null | awk '{print $3}')

    ensure_netbird_service
    configure_netbird_host_management_access "$docker_gateway"
    netbird_verify_host_management_reachable
    netbird_prepare_local_management_profile
    if [[ -f /var/lib/netbird/default.json ]] \
        && grep -qE 'localhost|127\.0\.0\.1|\[::1\]' /var/lib/netbird/default.json 2>/dev/null; then
        netbird down 2>/dev/null || true
    fi
    netbird_export_service_env

    netbird_prepare_enroll_credentials || return 1
    netbird_replace_same_name_peer_if_needed || \
        echo "[proxy-peer] same-name peer replace failed; continuing with netbird up." >&2
    echo "[proxy-peer] Enrolling NetBird peer on ${iface}." >&2
    netbird up \
        --setup-key "${NB_SETUP_KEY}" \
        --management-url "${NB_MANAGEMENT_URL:-https://api.netbird.io}" \
        --hostname "${NB_PEER_NAME}" \
        --interface-name "${iface}"

    wait_until 30 1 \
        "[proxy-peer] Timed out waiting for NetBird to bring up ${iface}" \
        ip link show "${iface}" >/dev/null 2>&1
}

supervise_netbird_daemon() {
    local iface="${1:-wt0}"

    while true; do
        sleep 10
        if ! netbird_daemon_ready; then
            echo "[proxy-peer] NetBird service daemon not responding; restarting." >&2
            netbird_export_service_env
            netbird service run --log-file console &
            wait_until 15 1 \
                "[proxy-peer] Timed out waiting for NetBird service daemon" \
                netbird_daemon_ready || true
        fi
        if ! ip link show "${iface}" >/dev/null 2>&1; then
            echo "[proxy-peer] NetBird interface ${iface} down; re-enrolling." >&2
            docker_gateway=$(ip -4 route show default dev eth0 2>/dev/null | awk '{print $3}')
            configure_netbird_host_management_access "$docker_gateway"
            netbird_prepare_local_management_profile
            netbird_export_service_env
            if netbird_prepare_enroll_credentials; then
                netbird_replace_same_name_peer_if_needed || true
                netbird up \
                    --setup-key "${NB_SETUP_KEY}" \
                    --management-url "${NB_MANAGEMENT_URL:-https://api.netbird.io}" \
                    --hostname "${NB_PEER_NAME}" \
                    --interface-name "${iface}" || true
            fi
        fi
    done
}

start_netbird "${NETBIRD_IFACE}"
netbird_set_dns_label
supervise_netbird_daemon "${NETBIRD_IFACE}" &

exec python3 /usr/local/bin/proxy-peer-hello.py --port "$HELLO_PORT"

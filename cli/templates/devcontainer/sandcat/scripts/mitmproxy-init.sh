#!/usr/bin/env bash
# cli/templates/devcontainer/sandcat/scripts/mitmproxy-init.sh
#
# Entrypoint wrapper for the mitmproxy container when NetBird is enabled.
# Runs as root, optionally enrolls mitmproxy as a NetBird peer on wt0,
# starts a DNS publishing loop so wg-client dnsmasq can resolve mesh FQDNs,
# then drops privileges to the mitmproxy user and execs the mitmweb command
# passed as arguments (the compose `command:` value).
#
# NetBird enrollment is optional: if NB_SETUP_KEY is not set (directly or via
# settings.json), mitmproxy starts normally without mesh connectivity.
#
# Expects:
#   NB_SETUP_KEY          - NetBird enrollment key (optional; read from settings
#                           if absent from environment)
#   NB_MANAGEMENT_URL     - NetBird management server URL (optional; default
#                           api.netbird.io; read from settings if absent)
#   NB_PEER_NAME          - Stable peer hostname in the NetBird management UI
#                           (required; set by compose)
#   NETBIRD_IFACE         - WireGuard interface name for NetBird mesh
#                           (default: wt0)
#   NETBIRD_WG_PORT       - UDP listen port for NetBird's wt0 (default: 51821).
#                           Must NOT be 51820: that port belongs to mitmproxy's
#                           userspace WireGuard server that wg-client dials.
#   NETBIRD_DNS_DOMAIN    - NetBird mesh DNS domain (default: netbird.selfhosted)
#   NETBIRD_DNS_CONF_PATH - Volume path where peer DNS records are published for
#                           wg-client dnsmasq (default: /home/mitmproxy/.mitmproxy/netbird-peers.conf)

set -euo pipefail

NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-}"
NB_PEER_NAME="${NB_PEER_NAME:?NB_PEER_NAME must be set by compose}"
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
# mitmproxy --mode wireguard binds UDP 51820; NetBird must use another port or
# mitmweb/mitmdump fails with "Failed to bind UDP socket to 0.0.0.0:51820".
NETBIRD_WG_PORT="${NETBIRD_WG_PORT:-51821}"
NETBIRD_DNS_DOMAIN="${NETBIRD_DNS_DOMAIN:-netbird.selfhosted}"
# Path in the mitmproxy-config volume where peer DNS records are published.
# wg-client reads this file and appends the records to its dnsmasq config so
# that NetBird FQDNs (e.g. myproject-proxy-peer.netbird.selfhosted) resolve for agents.
NETBIRD_DNS_CONF_PATH="${NETBIRD_DNS_CONF_PATH:-/home/mitmproxy/.mitmproxy/netbird-peers.conf}"
NETBIRD_PEER_LOG_PREFIX="${NETBIRD_PEER_LOG_PREFIX:-mitmproxy}"
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

# Allow enrollment against a self-hosted management server on the Docker host.
# mitmproxy has no iptables kill switch, so management traffic already leaves
# freely via eth0. This function adds explicit routing rules to ensure host-IP
# management traffic prefers eth0 even when NetBird later adds ip rules of its
# own, and opens any iptables OUTPUT rules needed for STUN/TURN.
# Args:
#   $1 - Docker bridge gateway IP
configure_netbird_host_management_access() {
    local docker_gateway=$1
    local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
    local host_ip port

    [[ -n "$docker_gateway" ]] || return 0

    host_ip=$(netbird_management_url_host "$mgmt_url") || return 0
    netbird_management_url_host_is_literal_ipv4 "$host_ip" || return 0

    port=$(netbird_management_url_port "$mgmt_url")

    if netbird_host_route_uses_gateway "$host_ip" "$docker_gateway"; then
        echo "[mitmproxy] Routing NetBird management traffic to ${host_ip}:${port} via eth0 (via ${docker_gateway})." >&2
        ip -4 route add "${host_ip}/32" via "${docker_gateway}" dev eth0 2>/dev/null || true
    else
        echo "[mitmproxy] Routing NetBird management traffic to ${host_ip}:${port} via eth0." >&2
    fi

    # Priority 50 ensures management traffic wins over NetBird's own ip rules.
    ip -4 rule add to "${host_ip}/32" lookup main priority 50 2>/dev/null || true

    iptables -C OUTPUT -o eth0 -d "$host_ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I OUTPUT 1 -o eth0 -d "$host_ip" -p tcp --dport "$port" -j ACCEPT
    # STUN/TURN (UDP 3478) used by NetBird signal relay.
    iptables -C OUTPUT -o eth0 -d "$host_ip" -p udp --dport 3478 -j ACCEPT 2>/dev/null \
        || iptables -I OUTPUT 1 -o eth0 -d "$host_ip" -p udp --dport 3478 -j ACCEPT
}

netbird_verify_host_management_reachable() {
    local mgmt_url="${NB_MANAGEMENT_URL:-}"
    local host_ip port check_url

    host_ip=$(netbird_management_url_host "$mgmt_url") || return 0
    netbird_management_url_host_is_literal_ipv4 "$host_ip" || return 0

    port=$(netbird_management_url_port "$mgmt_url")
    command -v curl >/dev/null 2>&1 || return 0

    check_url="${mgmt_url%/}/api/instance"
    wait_until 15 1 \
        "[mitmproxy] Cannot reach NetBird management at ${mgmt_url}; is the server running on the host (port ${port})?" \
        curl -sf --max-time 5 "$check_url" >/dev/null
}

netbird_export_service_env() {
    local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
    export NB_MANAGEMENT_URL="$mgmt_url"
    # Keep NetBird's WG listener off mitmproxy's WireGuard server port (51820).
    export NB_WIREGUARD_PORT="${NETBIRD_WG_PORT}"
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

    echo "[mitmproxy] Starting NetBird service daemon ($(netbird version 2>/dev/null || echo unknown))." >&2
    netbird service run --log-file console &

    wait_until 30 1 \
        "[mitmproxy] Timed out waiting for NetBird service daemon" \
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
    # Replace is best-effort. 0.72 stays NeedsLogin until netbird up --setup-key.
    netbird_replace_same_name_peer_if_needed || \
        echo "[mitmproxy] same-name peer replace failed; continuing with netbird up." >&2
    echo "[mitmproxy] Enrolling NetBird peer on ${iface} as '${NB_PEER_NAME}' (WG port ${NETBIRD_WG_PORT})." >&2
    if ! netbird up \
        --setup-key "${NB_SETUP_KEY}" \
        --management-url "${NB_MANAGEMENT_URL:-https://api.netbird.io}" \
        --hostname "${NB_PEER_NAME}" \
        --interface-name "${iface}" \
        --wireguard-port "${NETBIRD_WG_PORT}"; then
        echo "[mitmproxy] netbird up failed for ${iface}." >&2
        return 1
    fi

    if ! wait_until 30 1 \
        "[mitmproxy] Timed out waiting for NetBird to bring up ${iface}" \
        ip link show "${iface}" >/dev/null 2>&1; then
        return 1
    fi
}

supervise_netbird_daemon() {
    local iface="${1:-wt0}"

    while true; do
        sleep 10
        if ! netbird_daemon_ready; then
            echo "[mitmproxy] NetBird service daemon not responding; restarting." >&2
            netbird_export_service_env
            netbird service run --log-file console &
            wait_until 15 1 \
                "[mitmproxy] Timed out waiting for NetBird service daemon" \
                netbird_daemon_ready || true
        fi
        if ! ip link show "${iface}" >/dev/null 2>&1; then
            echo "[mitmproxy] NetBird interface ${iface} down; re-enrolling." >&2
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
                    --interface-name "${iface}" \
                    --wireguard-port "${NETBIRD_WG_PORT}" || true
            fi
        fi
    done
}

# Write dnsmasq-compatible address= records for all connected NetBird peers
# to $NETBIRD_DNS_CONF_PATH in the mitmproxy-config shared volume. wg-client
# reads this file via patch_dnsmasq_from_netbird_volume() so that NetBird
# FQDNs resolve inside agent containers without wg-client running NetBird.
#
# Also writes a `server=/<domain>/<ns_ip>` forward line when the management
# server has published a nameserver group (NetBird >= 0.28 with DNS enabled in
# the dashboard), enabling full wildcard resolution under the mesh domain.
publish_netbird_dns() {
    command -v jq >/dev/null 2>&1 || return 0
    local status_json
    status_json=$(netbird status --json 2>/dev/null) || return 0
    [[ -n "$status_json" ]] || return 0

    local tmp_file peer_records
    tmp_file=$(mktemp)
    peer_records=$(mktemp)

    # Nameserver forward line (best-effort; skipped when 0 nameservers configured).
    local ns_ip
    ns_ip=$(printf '%s' "$status_json" | jq -r '
        first(
            (.dnsServers // .nameservers // .dns // [])[]
            | select(.domains != null and (.domains | length) > 0)
            | (.servers // .ips // [.ip // empty] // [])[]
            | select(type == "string" and length > 0)
            | split(":")[0]
        ) // empty
    ' 2>/dev/null) || true
    if [[ -n "$ns_ip" ]] && [[ "$ns_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ || ( "$ns_ip" =~ ^[0-9a-fA-F:]+$ && "$ns_ip" == *:* ) ]]; then
        printf 'server=/%s/%s\n' "$NETBIRD_DNS_DOMAIN" "$ns_ip" >> "$tmp_file"
    fi

    # Per-peer address= records.
    # NetBird >= 0.28 renamed the peer address field from `ip` to `netbirdIp`
    # in `netbird status --json`. Accept either so DNS publishing keeps working
    # across client versions; strip a trailing /prefix if present.
    while IFS=$'\t' read -r fqdn ip; do
        [[ -n "$fqdn" && -n "$ip" ]] || continue
        [[ "$fqdn" == *"${NETBIRD_DNS_DOMAIN}"* ]] || continue
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || continue
        # host-record= gives an exact FQDN mapping; address= also covers subdomains.
        printf 'host-record=%s,%s\n' "$fqdn" "$ip" >> "$peer_records"
        printf 'address=/%s/%s\n' "$fqdn" "$ip" >> "$peer_records"
        # Alias without auto-generated IP suffix (e.g. myproject-proxy-peer.netbird.selfhosted
        # in addition to myproject-proxy-peer-100-64-0-5.netbird.selfhosted).
        local hostname="${fqdn%.${NETBIRD_DNS_DOMAIN}}"
        if [[ "$hostname" =~ ^(.+)-[0-9]{1,3}-[0-9]{1,3}$ ]]; then
            local alias_fqdn="${BASH_REMATCH[1]}.${NETBIRD_DNS_DOMAIN}"
            printf 'host-record=%s,%s\n' "$alias_fqdn" "$ip" >> "$peer_records"
            printf 'address=/%s/%s\n' "$alias_fqdn" "$ip" >> "$peer_records"
        fi
    done < <(printf '%s' "$status_json" | jq -r '
        (.peers.details // [])[]
        | . as $p
        | ($p.netbirdIp // $p.ip // empty | tostring | split("/")[0]) as $ip
        | select($p.fqdn != null and ($p.fqdn | tostring | length) > 0 and ($ip | test("^[0-9.]+$|^[0-9a-fA-F:]+$")))
        | [$p.fqdn, $ip] | @tsv
    ' 2>/dev/null)

    if [[ -s "$peer_records" ]]; then
        printf 'local=/%s/\n' "$NETBIRD_DNS_DOMAIN" >> "$tmp_file"
        cat "$peer_records" >> "$tmp_file"
    fi
    rm -f "$peer_records"

    # Atomically replace the published file only when content changed.
    if [[ -s "$tmp_file" ]]; then
        if ! diff -q "$tmp_file" "$NETBIRD_DNS_CONF_PATH" >/dev/null 2>&1; then
            cp "$tmp_file" "$NETBIRD_DNS_CONF_PATH"
            echo "[mitmproxy] Published NetBird DNS records to volume." >&2
        fi
    fi
    rm -f "$tmp_file"
}

# Periodically publish NetBird peer DNS records to the shared volume.
supervise_netbird_dns_publish() {
    while true; do
        sleep 10
        publish_netbird_dns 2>/dev/null || true
    done
}

main() {
    # ── Read NetBird credentials from settings if not in environment ─────────────
    # Prefer NB_SETUP_KEY from compose passthrough (sandcat exports it from layered
    # settings). Leave env empty when unset so prepare can flatten object-shaped
    # secrets from the mounted user settings.json (not project .sandcat/settings.json).
    local _settings_file="/config/settings.json"
    local _setup_key_from_compose=0
    [[ -n "${NB_SETUP_KEY:-}" ]] && _setup_key_from_compose=1
    if [[ -f "$_settings_file" ]] && command -v jq >/dev/null 2>&1; then
        if [[ -z "${NB_MANAGEMENT_URL:-}" ]]; then
            # Prefer enrollment-specific URL for container-side access to self-hosted server.
            local _enrollment_url
            _enrollment_url=$(jq -r '.netbird_enrollment_management_url // .netbird_management_url // empty' "$_settings_file" 2>/dev/null || true)
            if [[ -n "$_enrollment_url" ]]; then
                NB_MANAGEMENT_URL="$_enrollment_url"
                export NB_MANAGEMENT_URL
            fi
        fi
    fi

    # ── NetBird enrollment (optional, best-effort) ───────────────────────────────
    # Mesh enrollment must not block the L7 proxy. Prepare before the gate so
    # object-shaped settings secrets flatten; skip mesh if prepare fails.
    if ! netbird_prepare_enroll_credentials; then
        echo "[mitmproxy] Failed to prepare NetBird enroll credentials; starting L7 proxy without mesh." >&2
    elif [[ -n "${NB_SETUP_KEY:-}" ]]; then
        if [[ "$_setup_key_from_compose" -eq 0 ]]; then
            echo "[mitmproxy] Loaded NB_SETUP_KEY from $_settings_file (compose did not pass it)." >&2
        fi
        echo "[mitmproxy] NB_SETUP_KEY is set (${#NB_SETUP_KEY} chars); enrolling NetBird mesh." >&2
        if start_netbird "$NETBIRD_IFACE"; then
            netbird_set_dns_label
            publish_netbird_dns 2>/dev/null || true
            supervise_netbird_daemon "$NETBIRD_IFACE" &
            supervise_netbird_dns_publish &
        else
            echo "[mitmproxy] NetBird enrollment failed; starting L7 proxy without mesh." >&2
            echo "[mitmproxy] Check netbird_enrollment_key / NB_MANAGEMENT_URL, then recreate mitmproxy." >&2
            # Keep a supervisor so a later fix of the key/server can still bring wt0 up.
            supervise_netbird_daemon "$NETBIRD_IFACE" &
            supervise_netbird_dns_publish &
        fi
    else
        echo "[mitmproxy] NB_SETUP_KEY not set; starting without NetBird mesh." >&2
        echo "[mitmproxy] Hint: ensure compose passes NB_SETUP_KEY (enable_netbird) and sandcat exports netbird_enrollment_key." >&2
    fi

    # ── Clear stale dns.conf sentinel ────────────────────────────────────────────
    # The mitmproxy-config volume persists across restarts. Clearing here
    # (rather than in the compose entrypoint override) ensures the addon rewrites
    # it fresh on each start before wg-client reads it.
    rm -f /home/mitmproxy/.mitmproxy/dns.conf

    # ── Drop privileges and start mitmweb ────────────────────────────────────────
    exec gosu mitmproxy "$@"
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    main "$@"
fi

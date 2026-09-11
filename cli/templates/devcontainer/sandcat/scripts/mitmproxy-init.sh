#!/usr/bin/env bash
# cli/templates/devcontainer/sandcat/scripts/mitmproxy-init.sh
#
# Entrypoint wrapper for the mitmproxy container when NetBird is enabled.
# Clears healthcheck sentinels, publishes the CA cert, optionally enrolls
# mitmproxy as a NetBird peer on wt0 in the background, then runs
# docker-entrypoint.sh as a child so SIGTERM can call netbird down.
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
MITMPROXY_HOME="${MITMPROXY_HOME:-/home/mitmproxy/.mitmproxy}"
MITMPROXY_PUBLIC="${MITMPROXY_PUBLIC:-/mitmproxy-public}"
MITMPROXY_WEB_PASSWORD_FILE="${MITMPROXY_WEB_PASSWORD_FILE:-$MITMPROXY_HOME/web_password}"

# shellcheck source=/usr/local/lib/netbird-peer-lifecycle.sh
source "$NETBIRD_PEER_LIFECYCLE_PATH"

# True when $1 is a DNS-safe FQDN under $NETBIRD_DNS_DOMAIN (suffix match).
# Rejects substring matches (evil.<domain>.attacker) and names with '/'.
netbird_dns_fqdn_allowed() {
    local fqdn=$1
    [[ "$fqdn" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$fqdn" == "$NETBIRD_DNS_DOMAIN" || "$fqdn" == *".$NETBIRD_DNS_DOMAIN" ]]
}

# Write dnsmasq-compatible address= records for all connected NetBird peers
# to $NETBIRD_DNS_CONF_PATH in the mitmproxy-config shared volume. wg-client
# reads this file via patch_dnsmasq_from_netbird_volume() so that NetBird
# FQDNs resolve inside agent containers without wg-client running NetBird.
#
# Also writes a `server=/<domain>/<ns_ip>` forward line when the management
# server has published a nameserver group (NetBird >= 0.28 with DNS enabled in
# the dashboard), enabling full wildcard resolution under the mesh domain.
# `local=/<domain>/` is omitted when forwarding: it cancels `server=/`.
publish_netbird_dns() {
    command -v jq >/dev/null 2>&1 || return 0
    local status_json
    status_json=$(netbird status --json 2>/dev/null) || return 0
    [[ -n "$status_json" ]] || return 0

    local tmp_file peer_records have_server=false
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
        have_server=true
    fi

    # Per-peer address= records.
    # NetBird >= 0.28 renamed the peer address field from `ip` to `netbirdIp`
    # in `netbird status --json`. Accept either so DNS publishing keeps working
    # across client versions; strip a trailing /prefix if present.
    while IFS=$'\t' read -r fqdn ip; do
        [[ -n "$fqdn" && -n "$ip" ]] || continue
        netbird_dns_fqdn_allowed "$fqdn" || continue
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || continue
        # host-record= gives an exact FQDN mapping; address= also covers subdomains.
        printf 'host-record=%s,%s\n' "$fqdn" "$ip" >> "$peer_records"
        printf 'address=/%s/%s\n' "$fqdn" "$ip" >> "$peer_records"
        # Alias without auto-generated four-octet IP suffix
        # (myproject-proxy-100-64-0-5.netbird.selfhosted → myproject-proxy).
        local hostname="${fqdn%.${NETBIRD_DNS_DOMAIN}}"
        if [[ "$hostname" =~ ^(.+)-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}$ ]]; then
            local alias_fqdn="${BASH_REMATCH[1]}.${NETBIRD_DNS_DOMAIN}"
            if netbird_dns_fqdn_allowed "$alias_fqdn"; then
                printf 'host-record=%s,%s\n' "$alias_fqdn" "$ip" >> "$peer_records"
                printf 'address=/%s/%s\n' "$alias_fqdn" "$ip" >> "$peer_records"
            fi
        fi
    done < <(printf '%s' "$status_json" | jq -r '
        (.peers.details // [])[]
        | . as $p
        | ($p.netbirdIp // $p.ip // empty | tostring | split("/")[0]) as $ip
        | select($p.fqdn != null and ($p.fqdn | tostring | length) > 0 and ($ip | test("^[0-9.]+$|^[0-9a-fA-F:]+$")))
        | [$p.fqdn, $ip] | @tsv
    ' 2>/dev/null)

    if [[ -s "$peer_records" ]]; then
        if [[ "$have_server" != true ]]; then
            printf 'local=/%s/\n' "$NETBIRD_DNS_DOMAIN" >> "$tmp_file"
        fi
        cat "$peer_records" >> "$tmp_file"
    fi
    rm -f "$peer_records"

    # Atomically replace, including an empty file so vanished peers truncate.
    if [[ -s "$tmp_file" || -e "$NETBIRD_DNS_CONF_PATH" ]]; then
        if ! diff -q "$tmp_file" "$NETBIRD_DNS_CONF_PATH" >/dev/null 2>&1; then
            cp "$tmp_file" "${NETBIRD_DNS_CONF_PATH}.tmp"
            mv "${NETBIRD_DNS_CONF_PATH}.tmp" "$NETBIRD_DNS_CONF_PATH"
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

# Drop stale healthcheck sentinels before mitmweb or NetBird start. The
# mitmproxy-config volume persists across restarts; leaving dns.conf in place
# lets the healthcheck pass and wg-client read the previous run's upstream.
clear_mitmproxy_health_sentinels() {
    mkdir -p "$MITMPROXY_PUBLIC" "$MITMPROXY_HOME"
    chown -R mitmproxy:mitmproxy "$MITMPROXY_PUBLIC" 2>/dev/null || true
    rm -f "$MITMPROXY_HOME/dns.conf" "$MITMPROXY_PUBLIC/mitmproxy-ca-cert.pem"
}

# Copy the CA cert onto the agent-facing volume once mitmproxy writes it.
# Healthcheck gates on this file (same as the stock compose entrypoint).
publish_mitmproxy_ca_loop() {
    (
        while [[ ! -f "$MITMPROXY_HOME/mitmproxy-ca-cert.pem" ]]; do
            sleep 1
        done
        cp "$MITMPROXY_HOME/mitmproxy-ca-cert.pem" "$MITMPROXY_PUBLIC/mitmproxy-ca-cert.pem.tmp"
        mv "$MITMPROXY_PUBLIC/mitmproxy-ca-cert.pem.tmp" "$MITMPROXY_PUBLIC/mitmproxy-ca-cert.pem"
    ) &
}

# Extra CA bundles bind-mounted by apply_upstream_ca_bundles. enable_netbird
# deletes the compose entrypoint that used to install them, so the NetBird
# image entrypoint must do it before docker-entrypoint.sh drops privileges.
install_upstream_ca_bundles() {
    local src="${UPSTREAM_CA_DIR:-/upstream-ca}"
    local dest="${UPSTREAM_CA_INSTALL_DIR:-/usr/local/share/ca-certificates}"
    local bundle="${UPSTREAM_CA_CERTIFI_BUNDLE:-}"
    [[ -d "$src" ]] || return 0
    shopt -s nullglob
    local certs=("$src"/*.crt)
    ((${#certs[@]} > 0)) || return 0
    mkdir -p "$dest"
    cp "$src"/*.crt "$dest/" || return 1
    if [[ "$dest" == "/usr/local/share/ca-certificates" ]] \
        && command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates >/dev/null || return 1
    fi
    if [[ -z "$bundle" ]]; then
        command -v python3 >/dev/null 2>&1 || return 1
        bundle=$(python3 -c 'import certifi; print(certifi.where())') || return 1
    fi
    cat "$src"/*.crt >> "$bundle"
}

# wt0 is in this netns and NetBird's default policy is all-to-all. mitmproxy
# is a mesh client here: allow only replies to connections it initiated.
# A port list would miss mitmproxy's userspace WireGuard (UDP 51820).
lockdown_wt0_ingress() {
    local iface="${1:-$NETBIRD_IFACE}"
    command -v iptables >/dev/null 2>&1 || return 0
    ip link show "$iface" >/dev/null 2>&1 || return 0
    iptables -C INPUT -i "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -i "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -C INPUT -i "$iface" -j DROP 2>/dev/null \
        || iptables -A INPUT -i "$iface" -j DROP
}

ensure_mitmweb_password() {
    local pwfile="${MITMPROXY_WEB_PASSWORD_FILE}"
    mkdir -p "$(dirname "$pwfile")"
    if [[ ! -s "$pwfile" ]]; then
        umask 077
        dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '/+\n=' >"$pwfile"
        echo "[mitmproxy] generated mitmweb password; cat $pwfile" >&2
    fi
    cat "$pwfile"
}

# Mesh enrollment must not block the L7 proxy (healthcheck / wg-client).
maybe_start_netbird_mesh() {
    export NETBIRD_AFTER_UP=lockdown_wt0_ingress
    local _settings_file="/config/settings.json"
    local _setup_key_from_compose=0
    [[ -n "${NB_SETUP_KEY:-}" ]] && _setup_key_from_compose=1
    if [[ -f "$_settings_file" ]] && command -v jq >/dev/null 2>&1; then
        if [[ -z "${NB_MANAGEMENT_URL:-}" ]]; then
            local _enrollment_url
            _enrollment_url=$(jq -r '.netbird_enrollment_management_url // .netbird_management_url // empty' "$_settings_file" 2>/dev/null || true)
            if [[ -n "$_enrollment_url" ]]; then
                NB_MANAGEMENT_URL="$_enrollment_url"
                export NB_MANAGEMENT_URL
            fi
        fi
    fi

    if ! netbird_prepare_enroll_credentials; then
        echo "[mitmproxy] Failed to prepare NetBird enroll credentials; starting L7 proxy without mesh." >&2
        return 0
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
            supervise_netbird_daemon "$NETBIRD_IFACE" &
            supervise_netbird_dns_publish &
        fi
    else
        echo "[mitmproxy] NB_SETUP_KEY not set; starting without NetBird mesh." >&2
        echo "[mitmproxy] Hint: ensure compose passes NB_SETUP_KEY (enable_netbird) and sandcat exports netbird_enrollment_key." >&2
    fi
}

netbird_mitmproxy_cleanup() {
    netbird_shutdown
    if [[ -n "${MITMPROXY_CHILD_PID:-}" ]]; then
        kill "$MITMPROXY_CHILD_PID" 2>/dev/null || true
    fi
    local job
    for job in $(jobs -p); do
        kill "$job" 2>/dev/null || true
    done
    if [[ -n "${MITMPROXY_CHILD_PID:-}" ]]; then
        wait "$MITMPROXY_CHILD_PID" 2>/dev/null || true
    fi
}

main() {
    # Stay PID 1 so SIGTERM can run netbird down. Enrollment stays in the
    # background so NetBird cannot stall mitmweb / wg-client.
    clear_mitmproxy_health_sentinels
    install_upstream_ca_bundles || exit 1
    publish_mitmproxy_ca_loop

    local password
    password=$(ensure_mitmweb_password)
    local -a cmd_args=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--set" && "${2-}" == web_password=* ]]; then
            cmd_args+=(--set "web_password=${password}")
            shift 2
            continue
        fi
        cmd_args+=("$1")
        shift
    done

    maybe_start_netbird_mesh &

    docker-entrypoint.sh "${cmd_args[@]}" &
    MITMPROXY_CHILD_PID=$!
    trap netbird_mitmproxy_cleanup TERM INT
    wait "$MITMPROXY_CHILD_PID"
    local status=$?
    trap - TERM INT
    netbird_shutdown
    exit "$status"
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    main "$@"
fi

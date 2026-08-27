#!/usr/bin/env bats
#
# Structural contracts for the netbird integration.
# Key invariants:
#   - wg-client is a pure tunnel shim (no NetBird, no cap_add for NetBird).
#   - NetBird binary and sha256sum verification live in Dockerfile.mitmproxy.
#   - enable_netbird() adds cap_add to mitmproxy only when NetBird is enabled;
#     the template compose-proxy.yml has no mitmproxy cap_add by default.
#

setup() {
    load test_helper
    COMPOSE_PROXY="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
    COMPOSE_ALL="$SCT_TEMPLATEDIR/devcontainer/compose-all.yml"
}

@test "wg-client is the only service in compose-proxy.yml with cap_add" {
    # All service names that have a cap_add key — must be exactly one: wg-client.
    # (mitmproxy only gets cap_add after enable_netbird() runs on the deployed file.)
    run yq '[to_entries | .[] | select(.value | has("cap_add")) | .key] | .[]' \
        <(yq '.services' "$COMPOSE_PROXY")
    assert_output "wg-client"
}

@test "compose-proxy.yml template does not contain NB_SETUP_KEY by default" {
    run yq '[.services.mitmproxy.environment[]? | select(. == "NB_SETUP_KEY")] | length' \
        "$COMPOSE_PROXY"
    assert_output "0"
}

@test "compose-all.yml template does not reference netbird by default" {
    run grep -c "netbird" "$COMPOSE_ALL"
    assert_output "0"
}

@test "netbird.env pins version and per-arch sha256 checksums" {
    local env_file="$SCT_TEMPLATEDIR/devcontainer/sandcat/netbird.env"
    # shellcheck disable=SC1090
    source "$env_file"

    [[ -n "$NETBIRD_VERSION" ]]
    [[ "$NETBIRD_SHA256_AMD64" =~ ^[0-9a-f]{64}$ ]]
    [[ "$NETBIRD_SHA256_ARM64" =~ ^[0-9a-f]{64}$ ]]
}

@test "Dockerfile.mitmproxy verifies netbird tarball with sha256sum" {
    local dockerfile="$SCT_TEMPLATEDIR/devcontainer/sandcat/Dockerfile.mitmproxy"
    run grep -F 'sha256sum -c -' "$dockerfile"
    assert_success
    run grep -F 'NETBIRD_SHA256_AMD64' "$dockerfile"
    assert_success
    run grep -F 'NETBIRD_SHA256_ARM64' "$dockerfile"
    assert_success
}

@test "Dockerfile.mitmproxy builds on BASE_IMAGE so provider CLIs survive" {
    local dockerfile="$SCT_TEMPLATEDIR/devcontainer/sandcat/Dockerfile.mitmproxy"
    # A hardcoded FROM mitmproxy/mitmproxy would drop pass-cli / op from the
    # NetBird-enabled proxy image.
    run grep -F 'ARG BASE_IMAGE=mitmproxy/mitmproxy:latest' "$dockerfile"
    assert_success
    run grep -F 'FROM ${BASE_IMAGE}' "$dockerfile"
    assert_success
}

@test "Dockerfile.mitmproxy downloads netbird in a throwaway builder stage" {
    local dockerfile="$SCT_TEMPLATEDIR/devcontainer/sandcat/Dockerfile.mitmproxy"
    run grep -F 'AS netbird-build' "$dockerfile"
    assert_success
    run grep -F 'COPY --from=netbird-build /out/netbird /usr/local/bin/netbird' "$dockerfile"
    assert_success
}

@test "NetBird peer images install the shared lifecycle script" {
    local mitmproxy_dockerfile="$SCT_TEMPLATEDIR/devcontainer/sandcat/Dockerfile.mitmproxy"

    run grep -F 'COPY scripts/netbird-peer-lifecycle.sh /usr/local/lib/netbird-peer-lifecycle.sh' "$mitmproxy_dockerfile"
    assert_success
}

@test "mitmproxy-init replaces a same-name peer before up and labels it after start" {
    local init="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"
    local replace_line up_line label_line

    run grep -F 'NETBIRD_PEER_LIFECYCLE_PATH="${NETBIRD_PEER_LIFECYCLE_PATH:-/usr/local/lib/netbird-peer-lifecycle.sh}"' "$init"
    assert_success
    run grep -F 'source "$NETBIRD_PEER_LIFECYCLE_PATH"' "$init"
    assert_success
    replace_line=$(grep -n -m1 'netbird_replace_same_name_peer_if_needed' "$init" | cut -d: -f1)
    up_line=$(grep -n -m1 'netbird up \\' "$init" | cut -d: -f1)
    label_line=$(grep -n -m1 'netbird_set_dns_label' "$init" | cut -d: -f1)
    [[ "$replace_line" -lt "$up_line" ]]
    [[ "$label_line" -gt "$up_line" ]]
}

@test "mitmproxy-init continues when NetBird enrollment fails" {
    local init="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"
    # Guard against regressing to a hard `start_netbird` under set -e that
    # aborts before mitmweb and breaks wg-client depends_on.
    run grep -F 'if start_netbird' "$init"
    assert_success
    run grep -F 'starting L7 proxy without mesh' "$init"
    assert_success
}

@test "mitmproxy-init keeps NetBird WG port off mitmproxy WireGuard 51820" {
    local init="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"
    # NetBird and mitmproxy --mode wireguard cannot both bind UDP 51820 in the
    # same container; NetBird must use NETBIRD_WG_PORT (default 51821).
    run grep -F 'NETBIRD_WG_PORT="${NETBIRD_WG_PORT:-51821}"' "$init"
    assert_success
    run grep -F -- '--wireguard-port "${NETBIRD_WG_PORT}"' "$init"
    assert_success
    run grep -F 'export NB_WIREGUARD_PORT=' "$init"
    assert_success
}

@test "Dockerfile.wg-client does not reference NetBird" {
    local dockerfile="$SCT_TEMPLATEDIR/devcontainer/sandcat/Dockerfile.wg-client"
    run grep -i 'netbird' "$dockerfile"
    assert_failure
}

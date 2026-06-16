#!/usr/bin/env bats
#
# Structural contracts for the netbird integration.
# The key invariant: wg-client is and remains the only NET_ADMIN container.
#

setup() {
    load test_helper
    COMPOSE_PROXY="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
    COMPOSE_ALL="$SCT_TEMPLATEDIR/devcontainer/compose-all.yml"
}

@test "wg-client is the only service in compose-proxy.yml with cap_add" {
    # All service names that have a cap_add key — must be exactly one: wg-client.
    run yq '[to_entries | .[] | select(.value | has("cap_add")) | .key] | .[]' \
        <(yq '.services' "$COMPOSE_PROXY")
    assert_output "wg-client"
}

@test "compose-proxy.yml template does not contain NB_SETUP_KEY by default" {
    run yq '[.services."wg-client".environment[]? | select(. == "NB_SETUP_KEY")] | length' \
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

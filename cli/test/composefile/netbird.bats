#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/composefile.bash"
    # shellcheck source=netbird.bash
    source "$SCT_LIBDIR/netbird.bash"

    COMPOSE_FILE="$BATS_TEST_TMPDIR/compose-proxy.yml"
    cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/netbird.env" "$BATS_TEST_TMPDIR/netbird.env"
    cat >"$COMPOSE_FILE" <<'YAML'
services:
  wg-client:
    build:
      context: .
      dockerfile: Dockerfile.wg-client
    cap_add:
      - NET_ADMIN
YAML
}

teardown() {
    unstub_all
}

@test "enable_netbird adds NB_SETUP_KEY to wg-client environment" {
    enable_netbird "$COMPOSE_FILE"

    yq -e '.services."wg-client".environment[] | select(. == "NB_SETUP_KEY")' "$COMPOSE_FILE"
}

@test "enable_netbird is idempotent" {
    enable_netbird "$COMPOSE_FILE"
    enable_netbird "$COMPOSE_FILE"

    run yq '[.services."wg-client".environment[] | select(. == "NB_SETUP_KEY")] | length' "$COMPOSE_FILE"
    assert_output "1"
}

@test "enable_netbird adds NB_MANAGEMENT_URL when provided" {
    local management_url="https://netbird.internal"
    enable_netbird "$COMPOSE_FILE" "$management_url"

    run yq -r '.services."wg-client".environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=$management_url"
}

@test "enable_netbird with management URL is idempotent" {
    local management_url="https://netbird.internal"
    enable_netbird "$COMPOSE_FILE" "$management_url"
    enable_netbird "$COMPOSE_FILE" "$management_url"

    run yq '[.services."wg-client".environment[] | select(. == "NB_SETUP_KEY")] | length' "$COMPOSE_FILE"
    assert_output "1"

    run yq '[.services."wg-client".environment[] | select(test("^NB_MANAGEMENT_URL="))] | length' "$COMPOSE_FILE"
    assert_output "1"
}

@test "enable_netbird updates existing NB_MANAGEMENT_URL when provided" {
    enable_netbird "$COMPOSE_FILE" "https://old.example.com"
    enable_netbird "$COMPOSE_FILE" "https://new.example.com"

    run yq -r '.services."wg-client".environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=https://new.example.com"
}

@test "enable_netbird with empty management URL does not add NB_MANAGEMENT_URL" {
    enable_netbird "$COMPOSE_FILE" ""

    run yq '[.services."wg-client".environment[] | select(test("^NB_MANAGEMENT_URL="))] | length' "$COMPOSE_FILE"
    assert_output "0"
}

@test "enable_netbird omits NB_MANAGEMENT_URL for localhost without enrollment URL" {
    enable_netbird "$COMPOSE_FILE" "http://localhost:33073"

    run yq '[.services."wg-client".environment[] | select(test("^NB_MANAGEMENT_URL="))] | length' "$COMPOSE_FILE"
    assert_output "0"
}

@test "enable_netbird uses explicit enrollment URL for local self-hosted" {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/sandcat"
    echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"

    enable_netbird "$COMPOSE_FILE" "http://localhost:33073"

    run yq -r '.services."wg-client".environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=http://192.168.5.2:33073"
}

@test "enable_netbird sets NB_USE_LEGACY_ROUTING for host IP enrollment URL" {
    export HOME="$BATS_TEST_TMPDIR/home-enrollment"
    mkdir -p "$HOME/.config/sandcat"
    echo '{"netbird_enrollment_management_url": "http://192.168.5.2:33073"}' > "$HOME/.config/sandcat/settings.json"

    enable_netbird "$COMPOSE_FILE" "http://localhost:33073"

    run yq -r '.services."wg-client".environment[] | select(. == "NB_USE_LEGACY_ROUTING=true")' "$COMPOSE_FILE"
    assert_output "NB_USE_LEGACY_ROUTING=true"
}

@test "enable_netbird does not rewrite remote management URL" {
    enable_netbird "$COMPOSE_FILE" "https://netbird.example.com"

    run yq -r '.services."wg-client".environment[] | select(test("^NB_MANAGEMENT_URL="))' "$COMPOSE_FILE"
    assert_output "NB_MANAGEMENT_URL=https://netbird.example.com"

    run yq '[.services."wg-client".environment[] | select(. == "NB_USE_LEGACY_ROUTING=true")] | length' "$COMPOSE_FILE"
    assert_output "0"
}

@test "apply_netbird_build_args injects version and checksum build args" {
    apply_netbird_build_args "$COMPOSE_FILE"

    # shellcheck disable=SC1091
    source "$BATS_TEST_TMPDIR/netbird.env"
    run yq -r '.services."wg-client".build.args.NETBIRD_VERSION' "$COMPOSE_FILE"
    assert_output "$NETBIRD_VERSION"
    run yq -r '.services."wg-client".build.args.NETBIRD_SHA256_AMD64' "$COMPOSE_FILE"
    assert_output "$NETBIRD_SHA256_AMD64"
    run yq -r '.services."wg-client".build.args.NETBIRD_SHA256_ARM64' "$COMPOSE_FILE"
    assert_output "$NETBIRD_SHA256_ARM64"
}

@test "apply_netbird_build_args is idempotent" {
    apply_netbird_build_args "$COMPOSE_FILE"
    apply_netbird_build_args "$COMPOSE_FILE"

    run yq '.services."wg-client".build.args | length' "$COMPOSE_FILE"
    assert_output "3"
}

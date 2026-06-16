#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/composefile.bash"

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

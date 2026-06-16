#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/composefile.bash"

    COMPOSE_FILE="$BATS_TEST_TMPDIR/compose-proxy.yml"
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

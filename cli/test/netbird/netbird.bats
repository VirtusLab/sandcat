#!/usr/bin/env bats

setup() {
    load test_helper

    NETBIRD_CMD="$SCT_LIBEXECDIR/netbird/netbird"
    export NB_MANAGEMENT_URL="https://api.netbird.io"
    export NB_API_TOKEN="test-token"
}

teardown() {
    unstub_all
}

@test "netbird status calls GET /api/peers" {
    stub curl \
        "-sf -X GET -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[]'"
    run bash "$NETBIRD_CMD" status
    assert_success
}

@test "netbird peer remove requires --peer-id" {
    run bash "$NETBIRD_CMD" peer remove
    assert_failure
    assert_output --partial "peer-id"
}

@test "netbird peer remove calls netbird_peer_remove" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers/abc123 : :"
    run bash "$NETBIRD_CMD" peer remove --peer-id abc123
    assert_success
}

@test "netbird route add requires --network and --peer-id" {
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24
    assert_failure
    assert_output --partial "peer-id"
}

@test "netbird route add calls netbird_route_add" {
    stub curl \
        "-sf -X POST -H 'Authorization: Token test-token' -H 'Content-Type: application/json' -d '{\"network\":\"10.8.0.0/24\",\"peer\":\"abc123\",\"enabled\":true}' https://api.netbird.io/api/routes : echo '{\"id\":\"route1\"}'"
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24 --peer-id abc123
    assert_success
}

@test "netbird route remove requires --route-id" {
    run bash "$NETBIRD_CMD" route remove
    assert_failure
    assert_output --partial "route-id"
}

@test "netbird route remove calls netbird_route_remove" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/routes/route1 : :"
    run bash "$NETBIRD_CMD" route remove --route-id route1
    assert_success
}

@test "netbird with unknown subcommand prints usage and fails" {
    run bash "$NETBIRD_CMD" bogus
    assert_failure
    assert_output --partial "Usage"
}

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
        "-sS -f -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[]'"
    run bash "$NETBIRD_CMD" status
    assert_success
    assert_output --partial "No peers registered"
}

@test "netbird status prints peer list when peers exist" {
    stub curl \
        "-sS -f -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[{\"id\":\"peer1\",\"name\":\"wg-client\"}]'"
    run bash "$NETBIRD_CMD" status
    assert_success
    assert_output --partial "peer1"
}

@test "netbird peer remove requires --peer-id" {
    run bash "$NETBIRD_CMD" peer remove
    assert_failure
    assert_output --partial "peer-id"
}

@test "netbird peer remove errors when --peer-id has no value" {
    run bash "$NETBIRD_CMD" peer remove --peer-id
    assert_failure
    assert_output --partial "Option --peer-id requires a value"
}

@test "netbird peer remove calls netbird_peer_remove" {
    stub curl \
        "-sS -f -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://api.netbird.io/api/peers/abc123 : :"
    run bash "$NETBIRD_CMD" peer remove --peer-id abc123
    assert_success
}

@test "netbird route add requires --network and --peer-id" {
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24
    assert_failure
    assert_output --partial "peer-id"
}

@test "netbird route add errors when --network has no value" {
    run bash "$NETBIRD_CMD" route add --network
    assert_failure
    assert_output --partial "Option --network requires a value"
}

@test "netbird route add errors when --peer-id has no value" {
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24 --peer-id
    assert_failure
    assert_output --partial "Option --peer-id requires a value"
}

@test "netbird route add rejects non-CIDR network" {
    run bash "$NETBIRD_CMD" route add --network wd0 --peer-id abc123
    assert_failure
    assert_output --partial "CIDR"
}

@test "netbird route add calls netbird_route_add" {
    stub curl \
        "-sS -f -X POST -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{\"network\":\"10.8.0.0/24\",\"peer\":\"abc123\",\"enabled\":true}' https://api.netbird.io/api/routes : echo '{\"id\":\"route1\"}'"
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24 --peer-id abc123
    assert_success
    assert_output --partial "route1"
}

@test "netbird route remove requires --route-id" {
    run bash "$NETBIRD_CMD" route remove
    assert_failure
    assert_output --partial "route-id"
}

@test "netbird route remove errors when --route-id has no value" {
    run bash "$NETBIRD_CMD" route remove --route-id
    assert_failure
    assert_output --partial "Option --route-id requires a value"
}

@test "netbird route remove calls netbird_route_remove" {
    stub curl \
        "-sS -f -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://api.netbird.io/api/routes/route1 : :"
    run bash "$NETBIRD_CMD" route remove --route-id route1
    assert_success
}

@test "netbird with unknown subcommand prints usage and fails" {
    run bash "$NETBIRD_CMD" bogus
    assert_failure
    assert_output --partial "Usage"
}

@test "sandcat netbird status routes subcommand through module dispatcher" {
    stub curl \
        "-sS -f -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[]'"
    run bash "$SCT_ROOT/bin/sandcat" netbird status
    assert_success
}

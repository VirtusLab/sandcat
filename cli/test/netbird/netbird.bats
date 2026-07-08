#!/usr/bin/env bats

setup() {
    load test_helper

    NETBIRD_CMD="$SCT_LIBEXECDIR/netbird/netbird"
    export NB_MANAGEMENT_URL="https://api.netbird.io"
    export NB_API_TOKEN="test-token"
    export NB_ROUTE_GROUPS="grp-test"
}

teardown() {
    unstub_all
}

@test "netbird status calls GET /api/peers" {
    stub curl \
        "-sS -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n200' '[]'"
    run bash "$NETBIRD_CMD" status
    assert_success
    assert_output --partial "No peers registered"
}

@test "netbird status pretty-prints JSON with jq" {
    stub curl \
        "-sS -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n200' '[{\"id\":\"peer1\",\"name\":\"wg-client\"}]'"
    run bash "$NETBIRD_CMD" status
    assert_success
    assert_output --partial "peer1"
    refute_output --partial "ARGS:"
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
        "-sS -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers/abc123 : printf '\n200'"
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
        "-sS -X POST -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{\"description\":\"sandcat route 10-8-0-0-24\",\"network_id\":\"10-8-0-0-24\",\"enabled\":true,\"peer\":\"abc123\",\"network\":\"10.8.0.0/24\",\"metric\":9999,\"masquerade\":true,\"groups\":[\"grp-test\"],\"keep_route\":false}' -w * https://api.netbird.io/api/routes : printf '%s\n200' '{\"id\":\"route1\"}'"
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24 --peer-id abc123
    assert_success
    assert_output --partial "route1"
}

@test "netbird route add passes explicit --network-id" {
    stub curl \
        "-sS -X POST -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{\"description\":\"sandcat route reach-api\",\"network_id\":\"reach-api\",\"enabled\":true,\"peer\":\"abc123\",\"network\":\"100.79.107.115/32\",\"metric\":9999,\"masquerade\":true,\"groups\":[\"grp-test\"],\"keep_route\":false}' -w * https://api.netbird.io/api/routes : printf '%s\n200' '{\"id\":\"route1\"}'"
    run bash "$NETBIRD_CMD" route add --network 100.79.107.115/32 --peer-id abc123 --network-id reach-api
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
        "-sS -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/routes/route1 : printf '\n200'"
    run bash "$NETBIRD_CMD" route remove --route-id route1
    assert_success
}

@test "netbird route remove URL-encodes route id path segment" {
    stub curl \
        "-sS -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/routes/route%2Fone%3Fx%3D1 : printf '\n200'"
    run bash "$NETBIRD_CMD" route remove --route-id "route/one?x=1"
    assert_success
}

@test "netbird peer remove URL-encodes peer id path segment" {
    stub curl \
        "-sS -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers/peer%2Fabc%3Ffoo%3Dbar : printf '\n200'"
    run bash "$NETBIRD_CMD" peer remove --peer-id "peer/abc?foo=bar"
    assert_success
}

@test "netbird with unknown subcommand prints usage and fails" {
    run bash "$NETBIRD_CMD" bogus
    assert_failure
    assert_output --partial "Usage"
}

@test "netbird server without subcommand prints usage and fails" {
    run bash "$NETBIRD_CMD" server
    assert_failure
    assert_output --partial "Unknown server subcommand"
}

@test "sandcat netbird status routes subcommand through module dispatcher" {
    printf 'test\n' > "$SCT_ROOT/.version"
    stub curl \
        "-sS -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n200' '[]'"
    run bash "$SCT_ROOT/bin/sandcat" netbird status
    assert_success
}

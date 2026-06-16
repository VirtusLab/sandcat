#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/netbird.bash"

    export NB_MANAGEMENT_URL="https://api.netbird.io"
    export NB_API_TOKEN="test-token"
}

teardown() {
    unstub_all
}

@test "netbird_api fails when NB_API_TOKEN is unset" {
    unset NB_API_TOKEN
    run netbird_api "GET" "/api/peers"
    assert_failure
    assert_output --partial "NB_API_TOKEN"
}

@test "netbird_status calls GET /api/peers" {
    stub curl \
        "-sf -X GET -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[{\"id\":\"peer1\",\"connected\":true}]'"
    run netbird_status
    assert_success
    assert_output --partial "peer1"
}

@test "netbird_route_add calls POST /api/routes with network and peer" {
    stub curl \
        "-sf -X POST -H 'Authorization: Token test-token' -H 'Content-Type: application/json' -d '{\"network\":\"10.8.0.0/24\",\"peer\":\"peer1\",\"enabled\":true}' https://api.netbird.io/api/routes : echo '{\"id\":\"route1\"}'"
    run netbird_route_add "10.8.0.0/24" "peer1"
    assert_success
}

@test "netbird_route_remove calls DELETE /api/routes/:id" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/routes/route1 : :"
    run netbird_route_remove "route1"
    assert_success
}

@test "netbird_peer_remove calls DELETE /api/peers/:id" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers/peer1 : :"
    run netbird_peer_remove "peer1"
    assert_success
}

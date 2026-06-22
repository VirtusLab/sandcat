#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/netbird.bash"

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/sandcat"
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
    assert_output --partial "netbird_api_token"
}

@test "netbird_status calls GET /api/peers" {
    stub curl \
        "-sS -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n200' '[{\"id\":\"peer1\",\"connected\":true}]'"
    run netbird_status
    assert_success
    assert_output --partial "peer1"
}

@test "netbird_route_add calls POST /api/routes with network and peer" {
    stub curl \
        "-sS -X POST -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -d '{\"network\":\"10.8.0.0/24\",\"peer\":\"peer1\",\"enabled\":true}' -w * https://api.netbird.io/api/routes : printf '%s\n200' '{\"id\":\"route1\"}'"
    run netbird_route_add "10.8.0.0/24" "peer1"
    assert_success
}

@test "netbird_route_remove calls DELETE /api/routes/:id" {
    stub curl \
        "-sS -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/routes/route1 : printf '\n200'"
    run netbird_route_remove "route1"
    assert_success
}

@test "netbird_peer_remove calls DELETE /api/peers/:id" {
    stub curl \
        "-sS -X DELETE -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers/peer1 : printf '\n200'"
    run netbird_peer_remove "peer1"
    assert_success
}

@test "netbird_api reports authentication hint on HTTP 401" {
    stub curl \
        "-sS -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * https://api.netbird.io/api/peers : printf '%s\n401' 'unauthorized'"
    run netbird_api "GET" "/api/peers"
    assert_failure
    assert_output --partial "Authentication failed"
    assert_output --partial "netbird_api_token"
}

@test "netbird_api reports authentication hint on HTTP 404 with invalid token body" {
    stub curl \
        "-sS -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * http://localhost:33073/api/peers : printf '%s\n404' '{\"message\":\"invalid token: pat: *** not found\",\"code\":404}'"
    export NB_MANAGEMENT_URL="http://localhost:33073"
    run netbird_api "GET" "/api/peers"
    assert_failure
    assert_output --partial "Authentication failed"
    assert_output --partial "netbird_api_token"
    refute_output --partial "Endpoint not found"
}

@test "netbird_api reports management URL hint on HTTP 404" {
    stub curl \
        "-sS -X GET -H 'Authorization: Token test-token' -H 'Accept: application/json' -H 'Content-Type: application/json' -w * http://localhost:8080/api/peers : printf '%s\n404' 'not found'"
    export NB_MANAGEMENT_URL="http://localhost:8080"
    run netbird_api "GET" "/api/peers"
    assert_failure
    assert_output --partial "Endpoint not found"
    assert_output --partial "33073"
}

@test "netbird_management_base_url strips trailing /api suffix" {
    export NB_MANAGEMENT_URL="http://localhost:33073/api"
    run netbird_management_base_url
    assert_output "http://localhost:33073"
}

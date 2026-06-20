#!/usr/bin/env bats

setup() {
    load test_helper
    NETBIRD_IFACE="wt0"
}

teardown() {
    unstub_all
}

@test "trust_mitmproxy_ca copies cert to ca-dir and runs update-ca-certificates" {
    local ca_src="$BATS_TEST_TMPDIR/mitmproxy-ca-cert.pem"
    local ca_dir="$BATS_TEST_TMPDIR/ca-certs"
    mkdir -p "$ca_dir"
    echo "FAKE CERT" > "$ca_src"

    stub update-ca-certificates "--fresh : :"
    trust_mitmproxy_ca "$ca_src" "$ca_dir"

    test -f "$ca_dir/mitmproxy.crt"
}

@test "trust_mitmproxy_ca is a no-op when CA cert is absent" {
    run trust_mitmproxy_ca "$BATS_TEST_TMPDIR/missing.pem" "$BATS_TEST_TMPDIR/ca-dir"
    assert_success
}

@test "netbird_management_url_port extracts explicit port" {
    run netbird_management_url_port "http://192.168.5.2:33073"
    assert_output "33073"
}

@test "netbird_management_url_port defaults http to 80" {
    run netbird_management_url_port "http://192.168.5.2"
    assert_output "80"
}

@test "netbird_management_url_host extracts IPv4 host" {
    run netbird_management_url_host "http://192.168.5.2:33073"
    assert_output "192.168.5.2"
}

@test "netbird_management_url_host_is_literal_ipv4 accepts IPv4" {
    run netbird_management_url_host_is_literal_ipv4 "192.168.5.2"
    assert_success
}

@test "netbird_management_url_host_is_literal_ipv4 rejects hostnames" {
    run netbird_management_url_host_is_literal_ipv4 "netbird.example.com"
    assert_failure
}

@test "netbird_host_route_uses_gateway for off-subnet Colima host" {
    run netbird_host_route_uses_gateway "192.168.5.2" "172.23.0.1"
    assert_success
}

@test "netbird_host_route_uses_gateway is false when host is bridge gateway" {
    run netbird_host_route_uses_gateway "172.23.0.1" "172.23.0.1"
    assert_failure
}

@test "configure_netbird_host_management_access is a no-op without setup key" {
    unset NB_SETUP_KEY
    export NB_MANAGEMENT_URL="http://192.168.5.2:33073"
    run configure_netbird_host_management_access "172.17.0.1"
    assert_success
}

@test "configure_netbird_host_management_access is a no-op for cloud URL" {
    export NB_SETUP_KEY="test-key"
    export NB_MANAGEMENT_URL="https://api.netbird.io"
    run configure_netbird_host_management_access "172.17.0.1"
    assert_success
}

@test "configure_netbird_host_management_access is a no-op for hostname URL" {
    export NB_SETUP_KEY="test-key"
    export NB_MANAGEMENT_URL="https://netbird.example.com"
    run configure_netbird_host_management_access "172.17.0.1"
    assert_success
}

@test "start_netbird is a no-op when NB_SETUP_KEY is unset" {
    unset NB_SETUP_KEY
    run start_netbird "$NETBIRD_IFACE"
    assert_success
    refute_output --partial "netbird"
}

@test "set_netbird_fwmark sets fwmark 51821 on the NetBird interface" {
    stub ip "link show wt0 : :"
    stub wg "set wt0 fwmark 51821 : :"
    set_netbird_fwmark "wt0"
}

@test "set_netbird_fwmark is a no-op when interface does not exist" {
    stub ip "link show wt0 : return 1"
    run set_netbird_fwmark "wt0"
    assert_success
}

@test "supervise_netbird_daemon returns immediately when NB_SETUP_KEY is unset" {
    unset NB_SETUP_KEY
    run supervise_netbird_daemon "wt0"
    assert_success
}

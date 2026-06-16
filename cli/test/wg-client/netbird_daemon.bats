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

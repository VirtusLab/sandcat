#!/usr/bin/env bats
# Tests for volume-based NetBird DNS bridge in wg-client-init.sh.
#
# The old netbird_dns_nameserver_ip and patch_dnsmasq_for_netbird functions
# (which called `netbird status` directly on wg-client) have been replaced by
# patch_dnsmasq_from_netbird_volume, which reads records published by
# mitmproxy-init.sh into the shared mitmproxy-config volume.

setup() {
    load test_helper
    DNSMASQ_CONF="$BATS_TEST_TMPDIR/dnsmasq.conf"
    NETBIRD_PEERS_CONF="$BATS_TEST_TMPDIR/netbird-peers.conf"
    DNSMASQ_PID_FILE="$BATS_TEST_TMPDIR/dnsmasq.pid"
    export NETBIRD_PEERS_CONF DNSMASQ_PID_FILE
    printf '# existing config\nserver=1.1.1.1\n' > "$DNSMASQ_CONF"

    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$BATS_TEST_TMPDIR/bin/dnsmasq"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$BATS_TEST_TMPDIR/bin/dnsmasq-ready"
    chmod +x "$BATS_TEST_TMPDIR/bin/dnsmasq" "$BATS_TEST_TMPDIR/bin/dnsmasq-ready"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    unstub_all
}

# ── patch_dnsmasq_from_netbird_volume ────────────────────────────────────────

@test "patch_dnsmasq_from_netbird_volume is a no-op when peers file does not exist" {
    rm -f "$NETBIRD_PEERS_CONF"
    local before
    before=$(cat "$DNSMASQ_CONF")

    run patch_dnsmasq_from_netbird_volume "$DNSMASQ_CONF"
    assert_success

    assert_equal "$(cat "$DNSMASQ_CONF")" "$before"
}

@test "patch_dnsmasq_from_netbird_volume appends address= records from volume" {
    printf 'address=/test-proxy-peer.netbird.selfhosted/100.64.0.5\n' > "$NETBIRD_PEERS_CONF"

    patch_dnsmasq_from_netbird_volume "$DNSMASQ_CONF"

    run grep -c "address=/test-proxy-peer.netbird.selfhosted/100.64.0.5" "$DNSMASQ_CONF"
    assert_output "1"
}

@test "patch_dnsmasq_from_netbird_volume appends server= forward lines from volume" {
    printf 'server=/netbird.selfhosted/100.64.0.1\n' > "$NETBIRD_PEERS_CONF"

    patch_dnsmasq_from_netbird_volume "$DNSMASQ_CONF"

    run grep -c "server=/netbird.selfhosted/100.64.0.1" "$DNSMASQ_CONF"
    assert_output "1"
}

@test "patch_dnsmasq_from_netbird_volume is idempotent — does not duplicate records" {
    printf 'address=/test-proxy-peer.netbird.selfhosted/100.64.0.5\n' > "$NETBIRD_PEERS_CONF"

    patch_dnsmasq_from_netbird_volume "$DNSMASQ_CONF"
    patch_dnsmasq_from_netbird_volume "$DNSMASQ_CONF"

    run grep -c "address=/test-proxy-peer.netbird.selfhosted/100.64.0.5" "$DNSMASQ_CONF"
    assert_output "1"
}

@test "patch_dnsmasq_from_netbird_volume skips lines that are not dnsmasq directives" {
    printf 'host-record=peer.netbird.selfhosted,100.64.0.5\nsome-random-line\n# comment\n' > "$NETBIRD_PEERS_CONF"

    patch_dnsmasq_from_netbird_volume "$DNSMASQ_CONF"

    run grep -c "some-random-line" "$DNSMASQ_CONF"
    assert_output "0"

    run grep -c "# comment" "$DNSMASQ_CONF"
    assert_output "0"
}

@test "patch_dnsmasq_from_netbird_volume handles multiple records" {
    {
        printf 'server=/netbird.selfhosted/100.64.0.1\n'
        printf 'address=/peer-a.netbird.selfhosted/100.64.0.5\n'
        printf 'address=/peer-b.netbird.selfhosted/100.64.0.6\n'
    } > "$NETBIRD_PEERS_CONF"

    patch_dnsmasq_from_netbird_volume "$DNSMASQ_CONF"

    run grep -c "address=" "$DNSMASQ_CONF"
    assert_output "2"

    run grep -c "server=/netbird.selfhosted" "$DNSMASQ_CONF"
    assert_output "1"
}

@test "wg-client-init restarts dnsmasq when NetBird peers volume changes" {
    run grep -F 'peers_mtime' "$WG_CLIENT_INIT"
    assert_success
    run grep -F 'restart_dnsmasq "$conf"' "$WG_CLIENT_INIT"
    assert_success
}

@test "wg-client-init restarts dnsmasq instead of SIGHUP reload" {
    run grep -F 'restart_dnsmasq' "$WG_CLIENT_INIT"
    assert_success
    run grep -F 'reload_dnsmasq_sighup' "$WG_CLIENT_INIT"
    assert_failure
    run grep -F 'pgrep -x dnsmasq' "$WG_CLIENT_INIT"
    assert_failure
    run grep -F -- '--pid-file="$DNSMASQ_PID_FILE"' "$WG_CLIENT_INIT"
    assert_success
}

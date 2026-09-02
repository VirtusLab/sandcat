#!/usr/bin/env bats
# Tests for mitmproxy-init.sh NetBird DNS publishing into the shared volume.

setup() {
	load "$BATS_TEST_DIRNAME/../wg-client/test_helper"
	export NB_PEER_NAME="test-proxy"
	export NETBIRD_PEER_LIFECYCLE_PATH="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/netbird-peer-lifecycle.sh"
	# Re-source mitmproxy-init after wg-client helper (which sources wg-client-init).
	# shellcheck source=../../templates/devcontainer/sandcat/scripts/mitmproxy-init.sh
	source "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"

	NETBIRD_DNS_DOMAIN="netbird.selfhosted"
	NETBIRD_DNS_CONF_PATH="$BATS_TEST_TMPDIR/netbird-peers.conf"
	export NETBIRD_DNS_DOMAIN NETBIRD_DNS_CONF_PATH
	rm -f "$NETBIRD_DNS_CONF_PATH"

	STATUS_JSON="$BATS_TEST_TMPDIR/netbird-status.json"
}

teardown() {
	unstub_all
}

@test "publish_netbird_dns writes address= records from netbirdIp (NetBird >= 0.28)" {
	# Real NetBird status --json shape: peers.details[].netbirdIp (0.28+), not .ip.
	cat >"$STATUS_JSON" <<'JSON'
{
  "peers": {
    "total": 1,
    "connected": 1,
    "details": [
      {
        "fqdn": "test-proxy-peer.netbird.selfhosted",
        "netbirdIp": "100.79.176.190",
        "status": "Connected"
      }
    ]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	run cat "$NETBIRD_DNS_CONF_PATH"
	assert_success
	assert_output --partial "local=/netbird.selfhosted/"
	assert_output --partial "host-record=test-proxy-peer.netbird.selfhosted,100.79.176.190"
	assert_output --partial "address=/test-proxy-peer.netbird.selfhosted/100.79.176.190"
}

@test "publish_netbird_dns still accepts legacy peers.details[].ip" {
	cat >"$STATUS_JSON" <<'JSON'
{
  "peers": {
    "details": [
      {
        "fqdn": "test-proxy-peer.netbird.selfhosted",
        "ip": "100.64.0.5"
      }
    ]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	run cat "$NETBIRD_DNS_CONF_PATH"
	assert_success
	assert_output --partial "address=/test-proxy-peer.netbird.selfhosted/100.64.0.5"
}

@test "publish_netbird_dns strips CIDR suffix from netbirdIp" {
	cat >"$STATUS_JSON" <<'JSON'
{
  "peers": {
    "details": [
      {
        "fqdn": "test-proxy-peer.netbird.selfhosted",
        "netbirdIp": "100.79.176.190/16"
      }
    ]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	run cat "$NETBIRD_DNS_CONF_PATH"
	assert_success
	assert_output --partial "address=/test-proxy-peer.netbird.selfhosted/100.79.176.190"
	run grep -F '100.79.176.190/16' "$NETBIRD_DNS_CONF_PATH"
	assert_failure
}

@test "publish_netbird_dns writes nothing when peer address field is missing" {
	cat >"$STATUS_JSON" <<'JSON'
{
  "peers": {
    "details": [
      {
        "fqdn": "test-proxy-peer.netbird.selfhosted",
        "status": "Connected"
      }
    ]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	[[ ! -f "$NETBIRD_DNS_CONF_PATH" ]]
}

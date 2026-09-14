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

@test "publish_netbird_dns truncates stale records when no peers remain" {
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
	printf 'address=/stale.netbird.selfhosted/100.64.0.1\n' >"$NETBIRD_DNS_CONF_PATH"
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	[[ -f "$NETBIRD_DNS_CONF_PATH" ]]
	run grep -F 'stale.netbird.selfhosted' "$NETBIRD_DNS_CONF_PATH"
	assert_failure
}

@test "publish_netbird_dns rejects a substring domain match" {
	cat >"$STATUS_JSON" <<'JSON'
{
  "peers": {
	"details": [
	  {
		"fqdn": "evil.netbird.selfhosted.attacker.example",
		"netbirdIp": "100.64.0.9"
	  }
	]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	[[ ! -s "$NETBIRD_DNS_CONF_PATH" ]]
}

@test "publish_netbird_dns rejects an FQDN with a slash" {
	cat >"$STATUS_JSON" <<'JSON'
{
  "peers": {
	"details": [
	  {
		"fqdn": "foo/bar.netbird.selfhosted",
		"netbirdIp": "100.64.0.9"
	  }
	]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	[[ ! -s "$NETBIRD_DNS_CONF_PATH" ]]
}

@test "publish_netbird_dns strips a four-octet IP suffix alias" {
	cat >"$STATUS_JSON" <<'JSON'
{
  "peers": {
	"details": [
	  {
		"fqdn": "myapp-proxy-100-64-0-5.netbird.selfhosted",
		"netbirdIp": "100.64.0.5"
	  }
	]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	run cat "$NETBIRD_DNS_CONF_PATH"
	assert_success
	assert_output --partial "host-record=myapp-proxy.netbird.selfhosted,100.64.0.5"
	assert_output --partial "host-record=myapp-proxy-100-64-0-5.netbird.selfhosted,100.64.0.5"
	run grep -F 'host-record=myapp-proxy-100-64.netbird.selfhosted' "$NETBIRD_DNS_CONF_PATH"
	assert_failure
}

@test "publish_netbird_dns does not emit local= when forwarding to a nameserver" {
	cat >"$STATUS_JSON" <<'JSON'
{
  "dnsServers": [
	{
	  "domains": ["netbird.selfhosted"],
	  "servers": ["100.64.0.1:53"]
	}
  ],
  "peers": {
	"details": [
	  {
		"fqdn": "test-proxy-peer.netbird.selfhosted",
		"netbirdIp": "100.64.0.5"
	  }
	]
  }
}
JSON
	stub netbird "status --json : cat '$STATUS_JSON'"

	publish_netbird_dns

	run cat "$NETBIRD_DNS_CONF_PATH"
	assert_success
	assert_output --partial "server=/netbird.selfhosted/100.64.0.1"
	assert_output --partial "address=/test-proxy-peer.netbird.selfhosted/100.64.0.5"
	run grep -F 'local=/netbird.selfhosted/' "$NETBIRD_DNS_CONF_PATH"
	assert_failure
}

@test "clear_mitmproxy_health_sentinels deletes stale dns.conf and published CA first" {
	MITMPROXY_HOME="$BATS_TEST_TMPDIR/mitm-home"
	MITMPROXY_PUBLIC="$BATS_TEST_TMPDIR/mitm-public"
	mkdir -p "$MITMPROXY_HOME" "$MITMPROXY_PUBLIC"
	printf 'stale\n' >"$MITMPROXY_HOME/dns.conf"
	printf 'old-ca\n' >"$MITMPROXY_PUBLIC/mitmproxy-ca-cert.pem"

	clear_mitmproxy_health_sentinels

	[[ ! -e "$MITMPROXY_HOME/dns.conf" ]]
	[[ ! -e "$MITMPROXY_PUBLIC/mitmproxy-ca-cert.pem" ]]
}

@test "ensure_mitmweb_password persists a generated password" {
	MITMPROXY_HOME="$BATS_TEST_TMPDIR/mitm-home"
	MITMPROXY_WEB_PASSWORD_FILE="$MITMPROXY_HOME/web_password"
	mkdir -p "$MITMPROXY_HOME"

	ensure_mitmweb_password >/dev/null
	local pw
	pw=$(cat "$MITMPROXY_WEB_PASSWORD_FILE")
	[[ ${#pw} -ge 16 ]]
	ensure_mitmweb_password >/dev/null
	[[ "$(cat "$MITMPROXY_WEB_PASSWORD_FILE")" == "$pw" ]]
}

@test "install_upstream_ca_bundles copies PEMs into the trust store" {
	UPSTREAM_CA_DIR="$BATS_TEST_TMPDIR/upstream-ca"
	UPSTREAM_CA_INSTALL_DIR="$BATS_TEST_TMPDIR/ca-certificates"
	UPSTREAM_CA_CERTIFI_BUNDLE="$BATS_TEST_TMPDIR/certifi.pem"
	mkdir -p "$UPSTREAM_CA_DIR"
	printf '%s\n' '-----BEGIN CERTIFICATE-----' 'ABC' '-----END CERTIFICATE-----' \
		>"$UPSTREAM_CA_DIR/000-company.crt"
	: >"$UPSTREAM_CA_CERTIFI_BUNDLE"

	install_upstream_ca_bundles

	[[ -f "$UPSTREAM_CA_INSTALL_DIR/000-company.crt" ]]
	run grep -F 'BEGIN CERTIFICATE' "$UPSTREAM_CA_CERTIFI_BUNDLE"
	assert_success
}

@test "lockdown_wt0_ingress default-denies new INPUT on wt0" {
	local log="$BATS_TEST_TMPDIR/iptables.log"
	: >"$log"
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat >"$BATS_TEST_TMPDIR/bin/iptables" <<EOF
#!/bin/sh
echo "\$*" >>"$log"
case "\$*" in
	*-C*) exit 1 ;;
esac
exit 0
EOF
	cat >"$BATS_TEST_TMPDIR/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/iptables" "$BATS_TEST_TMPDIR/bin/ip"
	PATH="$BATS_TEST_TMPDIR/bin:$PATH" lockdown_wt0_ingress wt0

	run grep -F 'INPUT -i wt0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "$log"
	assert_success
	run grep -F 'INPUT -i wt0 -j DROP' "$log"
	assert_success
}

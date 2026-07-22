#!/usr/bin/env bats
# Tests for NetBird DNS domain forwarding via dnsmasq (Task 2)

setup() {
	load test_helper
	DNSMASQ_CONF="$BATS_TEST_TMPDIR/dnsmasq.conf"
	printf '# existing config\nserver=1.1.1.1\n' > "$DNSMASQ_CONF"
}

teardown() {
	unstub_all
}

# ── netbird_dns_nameserver_ip ────────────────────────────────────────────────

@test "netbird_dns_nameserver_ip returns IP from nameservers[].servers[]" {
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"100.64.0.1\"]}]}'"

	run netbird_dns_nameserver_ip
	assert_success
	assert_output "100.64.0.1"
}

@test "netbird_dns_nameserver_ip returns IP from dns[].servers[]" {
	stub netbird "status --json : printf '{\"dns\":[{\"servers\":[\"100.64.0.2\"]}]}'"

	run netbird_dns_nameserver_ip
	assert_success
	assert_output "100.64.0.2"
}

@test "netbird_dns_nameserver_ip returns empty when no nameservers configured" {
	stub netbird "status --json : printf '{\"nameservers\":[]}'"

	run netbird_dns_nameserver_ip
	assert_success
	assert_output ""
}

@test "netbird_dns_nameserver_ip returns empty when netbird status fails" {
	stub netbird "status --json : return 1"

	run netbird_dns_nameserver_ip
	assert_success
	assert_output ""
}

# ── patch_dnsmasq_for_netbird ────────────────────────────────────────────────

@test "patch_dnsmasq_for_netbird appends forward line when nameserver available" {
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"100.64.0.1\"]}]}'"

	patch_dnsmasq_for_netbird "$DNSMASQ_CONF"

	run grep -c "server=/netbird.selfhosted/100.64.0.1" "$DNSMASQ_CONF"
	assert_success
	assert_output "1"
}

@test "patch_dnsmasq_for_netbird is idempotent — does not duplicate forward line" {
	printf 'server=/netbird.selfhosted/100.64.0.1\n' >> "$DNSMASQ_CONF"
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"100.64.0.1\"]}]}'"

	patch_dnsmasq_for_netbird "$DNSMASQ_CONF"

	run grep -c "server=/netbird.selfhosted/100.64.0.1" "$DNSMASQ_CONF"
	assert_success
	assert_output "1"
}

@test "patch_dnsmasq_for_netbird is a no-op when nameserver unavailable" {
	stub netbird "status --json : printf '{\"nameservers\":[]}'"

	local before
	before=$(cat "$DNSMASQ_CONF")

	run patch_dnsmasq_for_netbird "$DNSMASQ_CONF"
	assert_success

	local after
	after=$(cat "$DNSMASQ_CONF")
	[[ "$before" == "$after" ]]
}

@test "patch_dnsmasq_for_netbird respects NETBIRD_DNS_DOMAIN override" {
	NETBIRD_DNS_DOMAIN="nb.corp.internal"
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"10.0.0.53\"]}]}'"

	patch_dnsmasq_for_netbird "$DNSMASQ_CONF"

	run grep "server=/nb.corp.internal/10.0.0.53" "$DNSMASQ_CONF"
	assert_success
}

@test "patch_dnsmasq_for_netbird is safe to call repeatedly (late-arriving nameserver)" {
	# First call: nameserver not yet available → no-op
	stub netbird "status --json : printf '{\"nameservers\":[]}'"
	patch_dnsmasq_for_netbird "$DNSMASQ_CONF"

	unstub_all

	# Second call (supervisor retry): nameserver now available → forward added
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"100.64.0.1\"]}]}'"
	patch_dnsmasq_for_netbird "$DNSMASQ_CONF"

	run grep -c "server=/netbird.selfhosted/100.64.0.1" "$DNSMASQ_CONF"
	assert_success
	assert_output "1"
}

# ── IP validation ────────────────────────────────────────────────────────────

@test "netbird_dns_nameserver_ip rejects malformed value with newline injection" {
	# JSON returns a string with a newline that would inject a second dnsmasq line
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"100.64.0.1\\nserver=/evil/1.2.3.4\"]}]}'"

	run netbird_dns_nameserver_ip
	assert_success
	# Must not contain anything — malformed value discarded
	refute_output --partial "evil"
	refute_output --partial "server="
}

@test "netbird_dns_nameserver_ip rejects hostname (only IPs allowed)" {
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"nameserver.example.com\"]}]}'"

	run netbird_dns_nameserver_ip
	assert_success
	# No bare IP should be printed (warning may appear on stderr, captured in output)
	refute_line --regexp '^[0-9]'
	refute_line --regexp '^[0-9a-fA-F:]+:[0-9a-fA-F:]'
}

@test "netbird_dns_nameserver_ip accepts IPv6 address" {
	stub netbird "status --json : printf '{\"nameservers\":[{\"servers\":[\"fd41:7314:3779::1\"]}]}'"

	run netbird_dns_nameserver_ip
	assert_success
	assert_output "fd41:7314:3779::1"
}

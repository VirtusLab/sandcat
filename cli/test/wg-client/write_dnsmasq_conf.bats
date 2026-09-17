#!/usr/bin/env bats

setup() {
	load test_helper
	DNS_CONF_FIXTURE="$BATS_TEST_TMPDIR/dns.conf"
	DNSMASQ_OUT="$BATS_TEST_TMPDIR/dnsmasq.conf"
}

@test "write_dnsmasq_conf routes unqualified names to Docker DNS and the rest upstream" {
	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT" myproj_default

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "no-resolv"
	assert_line "no-hosts"
	assert_line "listen-address=127.0.0.1"
	assert_line "bind-interfaces"
	assert_line "bogus-priv"
	# Empty-domain rule: single-label (sibling container) names → Docker DNS.
	assert_line "server=//127.0.0.11"
	assert_line "server=1.1.1.1"
	assert_line "server=8.8.8.8"
	# #113 regression guards: search domains must NOT be routed to Docker
	# (corporate search domains are intranet zones only the upstream knows),
	# and dotless queries must NOT be dropped (they carry sibling lookups).
	refute_output --partial "server=/myproj_default/"
	refute_output --partial "domain-needed"
}

@test "write_dnsmasq_conf uses custom upstream from dns.conf" {
	printf '10.0.0.10\n10.0.0.11\n' > "$DNS_CONF_FIXTURE"

	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT" myproj_default

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "server=10.0.0.10"
	assert_line "server=10.0.0.11"
	refute_line "server=1.1.1.1"
	refute_line "server=8.8.8.8"
}

@test "write_dnsmasq_conf emits the same config with no search domains" {
	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT"

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "server=//127.0.0.11"
	assert_line "server=1.1.1.1"
}

@test "write_dnsmasq_conf ignores search domains for routing (multiple given)" {
	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT" myproj_default cluster.local

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "server=//127.0.0.11"
	refute_output --partial "server=/myproj_default/"
	refute_output --partial "server=/cluster.local/"
}

@test "write_dnsmasq_conf falls back to defaults when dns.conf is empty" {
	: > "$DNS_CONF_FIXTURE"

	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT"

	run cat "$DNSMASQ_OUT"
	assert_success
	assert_line "server=1.1.1.1"
	assert_line "server=8.8.8.8"
}

@test "write_dnsmasq_conf truncates an existing config file" {
	printf 'leftover\n' > "$DNSMASQ_OUT"

	write_dnsmasq_conf "$DNS_CONF_FIXTURE" "$DNSMASQ_OUT"

	run cat "$DNSMASQ_OUT"
	assert_success
	refute_line "leftover"
}

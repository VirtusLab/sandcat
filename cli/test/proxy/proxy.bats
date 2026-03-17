#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/proxy/proxy
	source "$SCT_LIBEXECDIR/proxy/proxy"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	touch "$COMPOSE_FILE"
}

teardown() {
	unstub_all
}

@test "proxy stops web mode, runs console, restores web mode" {
	stub docker \
		"compose -f $COMPOSE_FILE stop wg-client mitmproxy : :" \
		"compose -f $COMPOSE_FILE run --rm -it mitmproxy mitmproxy --mode wireguard -s /scripts/mitmproxy_addon.py : :" \
		"compose -f $COMPOSE_FILE up -d mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_success
	assert_output --partial "Stopping proxy"
	assert_output --partial "Restoring proxy"
}

@test "proxy restores web mode even if console exits with error" {
	stub docker \
		"compose -f $COMPOSE_FILE stop wg-client mitmproxy : :" \
		"compose -f $COMPOSE_FILE run --rm -it mitmproxy mitmproxy --mode wireguard -s /scripts/mitmproxy_addon.py : exit 1" \
		"compose -f $COMPOSE_FILE up -d mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_success
	assert_output --partial "Restoring proxy"
}

@test "proxy passes additional arguments to mitmproxy" {
	stub docker \
		"compose -f $COMPOSE_FILE stop wg-client mitmproxy : :" \
		"compose -f $COMPOSE_FILE run --rm -it mitmproxy mitmproxy --mode wireguard -s /scripts/mitmproxy_addon.py --set flow_detail=3 : :" \
		"compose -f $COMPOSE_FILE up -d mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy --set flow_detail=3
	assert_success
}

#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/restart/restart
	source "$SCT_LIBEXECDIR/restart/restart"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	touch "$COMPOSE_FILE"
}

teardown() {
	unstub_all
}

@test "restart restarts proxy AND agent when both are running" {
	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : echo 'proxy-id'" \
		"compose -f $COMPOSE_FILE ps agent --status running --quiet : echo 'agent-id'" \
		"compose -f $COMPOSE_FILE restart mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --wait --wait-timeout 60 mitmproxy : :" \
		"compose -f $COMPOSE_FILE restart wg-client : :" \
		"compose -f $COMPOSE_FILE up -d --wait --wait-timeout 60 wg-client : :" \
		"compose -f $COMPOSE_FILE restart agent : :"

	cd "$BATS_TEST_TMPDIR"
	run restart
	assert_success
	assert_output --partial "Restarting proxy"
}

@test "restart skips agent restart when agent is not running" {
	# When only the proxy stack is up (agent stopped or never started),
	# the netns-relink step is a no-op — restarting a stopped agent would
	# start it unexpectedly.
	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : echo 'proxy-id'" \
		"compose -f $COMPOSE_FILE ps agent --status running --quiet : :" \
		"compose -f $COMPOSE_FILE restart mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --wait --wait-timeout 60 mitmproxy : :" \
		"compose -f $COMPOSE_FILE restart wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run restart
	assert_success
	assert_output --partial "Restarting proxy"
}

@test "restart warns when proxy is not running" {
	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : :"

	cd "$BATS_TEST_TMPDIR"
	run restart
	assert_success
	assert_output --partial "not running"
}

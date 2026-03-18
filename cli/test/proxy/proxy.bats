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

@test "proxy switches to console, attaches, then restores web mode" {
	stub docker \
		"compose -f $COMPOSE_FILE -f * up -d --force-recreate mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : :" \
		"compose -f $COMPOSE_FILE ps -q mitmproxy : echo container-id" \
		"attach container-id : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_success
	assert_output --partial "Switching proxy to console mode"
	assert_output --partial "Restoring proxy"
}

@test "proxy passes additional arguments to mitmproxy command" {
	local captured="$BATS_TEST_TMPDIR/captured-override"

	stub docker \
		"compose -f $COMPOSE_FILE -f * up -d --force-recreate mitmproxy : cat \"\$5\" > '$captured'" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : :" \
		"compose -f $COMPOSE_FILE ps -q mitmproxy : echo container-id" \
		"attach container-id : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy --set flow_detail=3
	assert_success

	run grep 'flow_detail=3' "$captured"
	assert_success
}

@test "proxy restores web mode when wg-client restart fails during switch" {
	stub docker \
		"compose -f $COMPOSE_FILE -f * up -d --force-recreate mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : exit 1" \
		"compose -f $COMPOSE_FILE up -d --force-recreate mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_failure
}

@test "proxy restores web mode and propagates error on console failure" {
	stub docker \
		"compose -f $COMPOSE_FILE -f * up -d --force-recreate mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : :" \
		"compose -f $COMPOSE_FILE ps -q mitmproxy : echo container-id" \
		"attach container-id : exit 1" \
		"compose -f $COMPOSE_FILE up -d --force-recreate mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --force-recreate wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run proxy
	assert_failure
	assert_output --partial "Restoring proxy"
}

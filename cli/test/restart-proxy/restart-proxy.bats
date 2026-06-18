#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/restart-proxy/restart-proxy
	source "$SCT_LIBEXECDIR/restart-proxy/restart-proxy"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	touch "$COMPOSE_FILE"
}

teardown() {
	unstub_all
}

@test "restart-proxy restarts when proxy is running" {
	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : echo 'proxy-id'" \
		"compose -f $COMPOSE_FILE restart mitmproxy : :" \
		"compose -f $COMPOSE_FILE up -d --wait --wait-timeout 60 mitmproxy : :" \
		"compose -f $COMPOSE_FILE restart wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run restart-proxy
	assert_success
	assert_output --partial "Restarting proxy"
}

@test "restart-proxy warns when proxy is not running" {
	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : :"

	cd "$BATS_TEST_TMPDIR"
	run restart-proxy
	assert_success
	assert_output --partial "not running"
}

@test "restart-proxy exports management URL from settings when env is unset" {
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/sandcat"
	echo '{"netbird_management_url": "https://management.settings.example.com"}' > "$HOME/.config/sandcat/settings.json"
	unset NB_MANAGEMENT_URL

	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : :"

	cd "$BATS_TEST_TMPDIR"
	restart-proxy
	[[ "$NB_MANAGEMENT_URL" == "https://management.settings.example.com" ]]
}

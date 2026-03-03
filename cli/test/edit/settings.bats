#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/edit/settings
	source "$SCT_LIBEXECDIR/edit/settings"

	mkdir -p "$BATS_TEST_TMPDIR/$SCT_PROJECT_DIR"
	SETTINGS_FILE="$BATS_TEST_TMPDIR/$SCT_PROJECT_DIR/settings.json"
	touch "$SETTINGS_FILE"
}

teardown() {
	unstub_all
}

@test "settings opens editor for default pattern" {
	unset -f open_editor
	stub open_editor \
		"$SETTINGS_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run settings
	assert_success
}

@test "settings restarts proxy when file modified and proxy running" {
	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	touch "$COMPOSE_FILE"

	unset -f open_editor
	stub open_editor \
		"$SETTINGS_FILE : sleep 1 && touch '$SETTINGS_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : echo 'proxy-container-id'" \
		"compose -f $COMPOSE_FILE restart mitmproxy : :" \
		"compose -f $COMPOSE_FILE restart wg-client : :"

	cd "$BATS_TEST_TMPDIR"
	run settings
	assert_output --partial "Restarting proxy"
}

@test "settings skips restart when file unchanged" {
	unset -f open_editor
	stub open_editor \
		"$SETTINGS_FILE : true"

	cd "$BATS_TEST_TMPDIR"
	run settings
	assert_success
	assert_output --partial "Settings file unchanged. Skipping restart."
}

@test "settings skips restart when proxy not running" {
	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	touch "$COMPOSE_FILE"

	unset -f open_editor
	stub open_editor \
		"$SETTINGS_FILE : sleep 1 && touch '$SETTINGS_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps mitmproxy --status running --quiet : :"

	cd "$BATS_TEST_TMPDIR"
	run settings
	assert_success
	assert_output --partial "proxy service is not running. Skipping restart."
}

#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/edit/compose
	source "$SCT_LIBEXECDIR/edit/compose"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	touch "$COMPOSE_FILE"
}

teardown() {
	unstub_all
}

@test "edit opens compose file in editor" {
	unset -f open_editor
	stub open_editor \
		"$COMPOSE_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run edit
	assert_success
}

@test "edit restarts containers when file modified and containers running (default)" {
	unset -f open_editor
	stub open_editor \
		"$COMPOSE_FILE : sleep 1 && touch '$COMPOSE_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet : echo running" \
		"compose -f $COMPOSE_FILE up -d : :"

	cd "$BATS_TEST_TMPDIR"
	run edit
	assert_success
	assert_output --partial "Compose file was modified. Restarting containers..."
	refute_output --partial "sandcat up -d"
}

@test "edit confirms save when file modified and no containers running" {
	unset -f open_editor
	stub open_editor \
		"$COMPOSE_FILE : sleep 1 && touch '$COMPOSE_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet : :"

	cd "$BATS_TEST_TMPDIR"
	run edit
	assert_success
	assert_output --partial "Compose file was modified."
	refute_output --partial "sandcat up -d"
}

@test "edit reports no changes when file unchanged" {
	unset -f open_editor
	stub open_editor \
		"$COMPOSE_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run edit
	assert_success
	assert_output --partial "No changes detected."
}

@test "edit with --no-restart warns when modified and containers running" {
	unset -f open_editor
	stub open_editor \
		"$COMPOSE_FILE : sleep 1 && touch '$COMPOSE_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet : echo running"

	cd "$BATS_TEST_TMPDIR"
	run edit --no-restart
	assert_success
	assert_output --partial "Compose file was modified, and you have containers running."
	assert_output --partial "sandcat compose up -d"
}

@test "edit respects SANDCAT_NO_RESTART env var when modified and containers running" {
	unset -f open_editor
	stub open_editor \
		"$COMPOSE_FILE : sleep 1 && touch '$COMPOSE_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet : echo running"

	export SANDCAT_NO_RESTART=true
	cd "$BATS_TEST_TMPDIR"
	run edit
	assert_success
	assert_output --partial "Compose file was modified, and you have containers running."
	assert_output --partial "sandcat compose up -d"
	unset SANDCAT_NO_RESTART
}

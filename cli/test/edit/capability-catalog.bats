#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/edit/capability-catalog
	source "$SCT_LIBEXECDIR/edit/capability-catalog"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer/sandcat"
	CATALOG_FILE="$BATS_TEST_TMPDIR/.devcontainer/sandcat/capability-catalog.json"
	touch "$CATALOG_FILE"
	touch "$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
	COMPOSE_FILE="$BATS_TEST_TMPDIR/.devcontainer/compose-all.yml"
}

teardown() {
	unstub_all
}

@test "capability-catalog opens project catalog in editor" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_success
}

@test "capability-catalog fails when file missing" {
	rm "$CATALOG_FILE"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_failure
	assert_output --partial "No capability catalog found"
	assert_output --partial "sandcat init --capability"
}

@test "capability-catalog rejects unknown options" {
	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --no-restart
	assert_failure
	assert_output --partial "Unknown option"
}

@test "capability-catalog does not restart by default when file modified" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog
	assert_success
	refute_output --partial "Restarting capability-runtime"
}

@test "capability-catalog --restart restarts only capability-runtime when modified and running" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet capability-runtime : echo cid" \
		"compose -f $COMPOSE_FILE restart capability-runtime : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "Catalog was modified. Restarting capability-runtime..."
}

@test "capability-catalog --restart does not restart when file unchanged" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "No changes detected."
}

@test "capability-catalog --restart warns when sidecar is not running" {
	unset -f open_editor
	stub open_editor \
		"$CATALOG_FILE : sleep 1 && touch '$CATALOG_FILE'"

	stub docker \
		"compose -f $COMPOSE_FILE ps --status running --quiet capability-runtime : :"

	cd "$BATS_TEST_TMPDIR"
	run capability-catalog --restart
	assert_success
	assert_output --partial "capability-runtime is not running; catalog was saved but not reloaded."
	refute_output --partial "Restarting capability-runtime"
}

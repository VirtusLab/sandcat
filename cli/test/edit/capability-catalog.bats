#!/usr/bin/env bats

setup() {
	load test_helper

	# shellcheck source=../../libexec/edit/capability-catalog
	source "$SCT_LIBEXECDIR/edit/capability-catalog"

	mkdir -p "$BATS_TEST_TMPDIR/.devcontainer/sandcat"
	CATALOG_FILE="$BATS_TEST_TMPDIR/.devcontainer/sandcat/capability-catalog.json"
	touch "$CATALOG_FILE"
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

#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/settings
	source "$SCT_LIBEXECDIR/init/settings"
}

teardown() {
	unstub_all
}

@test "settings creates settings file from template" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"

	run settings "$settings_file" "github"
	assert_success

	# File should exist
	[[ -f "$settings_file" ]]

	assert_output --partial "Settings file created at:"
}

@test "settings creates parent directories" {
	local settings_file="$BATS_TEST_TMPDIR/nested/deep/settings.json"

	run settings "$settings_file" "github"
	assert_success

	[[ -f "$settings_file" ]]
}

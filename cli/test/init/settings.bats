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

	assert_output --partial "Settings file created at"
}

@test "settings creates parent directories" {
	local settings_file="$BATS_TEST_TMPDIR/nested/deep/settings.json"

	run settings "$settings_file" "github"
	assert_success

	[[ -f "$settings_file" ]]
}

@test "settings creates empty settings.local.json scaffold when absent" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"
	local local_settings="$BATS_TEST_TMPDIR/settings.local.json"

	run settings "$settings_file" "github"
	assert_success

	[[ -f "$local_settings" ]]
	run cat "$local_settings"
	assert_output "{}"
}

@test "settings preserves an existing settings.local.json" {
	local settings_file="$BATS_TEST_TMPDIR/settings.json"
	local local_settings="$BATS_TEST_TMPDIR/settings.local.json"

	# Simulate a user who already put real credentials in the local file.
	printf '{"secrets":{"MY_TOKEN":{"value":"real"}}}' > "$local_settings"

	run settings "$settings_file" "github"
	assert_success

	run cat "$local_settings"
	assert_output --partial '"real"'
}

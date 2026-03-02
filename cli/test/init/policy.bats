#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../libexec/init/policy
	source "$SCT_LIBEXECDIR/init/policy"
}

teardown() {
	unstub_all
}

@test "policy creates policy file from template" {
	local policy_file="$BATS_TEST_TMPDIR/settings.json"

	run policy "$policy_file" "github"
	assert_success

	# File should exist
	[[ -f "$policy_file" ]]

	assert_output --partial "Policy file created at:"
}

@test "policy creates parent directories" {
	local policy_file="$BATS_TEST_TMPDIR/nested/deep/settings.json"

	run policy "$policy_file" "github"
	assert_success

	[[ -f "$policy_file" ]]
}

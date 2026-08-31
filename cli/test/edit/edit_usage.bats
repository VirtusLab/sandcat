#!/usr/bin/env bats

setup() {
	load test_helper
}

@test "sandcat edit usage does not list capability-catalog" {
	run bash "$SCT_LIBEXECDIR/edit/edit"
	assert_failure
	refute_output --partial "capability-catalog"
	assert_output --partial "compose"
	assert_output --partial "project-settings"
}

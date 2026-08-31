#!/usr/bin/env bats

setup() {
	load test_helper
}

@test "libexec has no netbird module directory" {
	[[ ! -d "$SCT_LIBEXECDIR/netbird" ]]
}

@test "netbird.bash has no netbird_api function" {
	run grep -E '^netbird_api\(\)' "$SCT_LIBDIR/netbird.bash"
	assert_failure
}

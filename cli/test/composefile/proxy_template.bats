#!/usr/bin/env bats

setup() {
	load test_helper
}

@test "compose-proxy.yml does not mount l7_revoke_rpc" {
	run grep -F "l7_revoke_rpc" "$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
	assert_failure
}

@test "compose-proxy.yml does not mention CAPABILITY_L7_RECORD" {
	run grep -F "CAPABILITY_L7_RECORD" "$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
	assert_failure
}

@test "composefile.bash has no enable_capability function" {
	run grep -E '^enable_capability\(\)' "$SCT_LIBDIR/composefile.bash"
	assert_failure
}

#!/usr/bin/env bats

setup() {
	load test_helper
}

@test "proxy-peer-init fails without NB_SETUP_KEY" {
	run bash "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-init.sh"
	assert_failure
	assert_output --partial "NB_SETUP_KEY is required"
}

#!/usr/bin/env bats

setup() {
	load test_helper
}

@test "proxy-peer-init fails without NB_SETUP_KEY" {
	run bash "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-init.sh"
	assert_failure
	assert_output --partial "NB_SETUP_KEY is required"
}

@test "proxy-peer-init requires compose to set NB_PEER_NAME" {
	run grep -F 'NB_PEER_NAME="${NB_PEER_NAME:?NB_PEER_NAME must be set by compose}"' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-init.sh"
	assert_success
}

@test "proxy-peer-init has no legacy peer-proxy default" {
	run grep -F 'NB_PEER_NAME="${NB_PEER_NAME:-peer-proxy}"' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/proxy-peer-init.sh"
	assert_failure
}

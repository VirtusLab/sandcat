#!/usr/bin/env bats

setup() {
	load "$BATS_TEST_DIRNAME/../composefile/test_helper"
}

@test "settings-proxy-peer.json allows proxy-peer mesh IP on port 8080" {
	local template="$SCT_TEMPLATEDIR/settings-proxy-peer.json"

	[[ -f "$template" ]]

	run yq -r '.network[] | select(.action == "allow") | .port' "$template"
	assert_success
	assert_output "8080"

	run yq -r '.network[] | select(.action == "allow") | .host' "$template"
	assert_success
	assert_output "REPLACE_PROXY_PEER_MESH_IP"
}

#!/usr/bin/env bats

setup() {
	load "$BATS_TEST_DIRNAME/../composefile/test_helper"
}

@test "settings-proxy-peer.json template is rewritten by netbird_apply_peer_names_to_layer1_example" {
	local template="$SCT_TEMPLATEDIR/settings-proxy-peer.json"

	[[ -f "$template" ]]

	run yq -r '.network[] | select(.action == "allow") | .port' "$template"
	assert_success
	assert_output "8080"

	run yq -r '.network[] | select(.action == "allow") | .host' "$template"
	assert_success
	assert_output "REPLACE_PROXY_PEER_FQDN"
}

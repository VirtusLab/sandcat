#!/usr/bin/env bats

setup() {
	load test_helper
}

@test "compose-proxy-peer defines proxy-peer service with NET_ADMIN" {
	yq -e '.services["proxy-peer"].cap_add[] | select(. == "NET_ADMIN")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy-peer.yml"
}

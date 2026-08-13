#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/composefile.bash"

	COMPOSE_DIR="$BATS_TEST_TMPDIR/devcontainer"
	mkdir -p "$COMPOSE_DIR/sandcat/scripts"
	cp "$SCT_TEMPLATEDIR/devcontainer/compose-all.yml" "$COMPOSE_DIR/compose-all.yml"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/netbird.env" "$COMPOSE_DIR/sandcat/netbird.env"
}

@test "compose-proxy-peer defines proxy-peer service with NET_ADMIN" {
	yq -e '.services["proxy-peer"].cap_add[] | select(. == "NET_ADMIN")' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy-peer.yml"
}

@test "enable_proxy_peer sets hostname and NB_PEER_NAME from argument" {
	enable_proxy_peer "$COMPOSE_DIR" "myapp-sandbox-proxy-peer"

	run yq -r '.services."proxy-peer".hostname' "$COMPOSE_DIR/sandcat/compose-proxy-peer.yml"
	assert_output "myapp-sandbox-proxy-peer"
	run yq -r '.services."proxy-peer".environment[] | select(test("^NB_PEER_NAME="))' \
		"$COMPOSE_DIR/sandcat/compose-proxy-peer.yml"
	assert_output "NB_PEER_NAME=myapp-sandbox-proxy-peer"
}

@test "enable_proxy_peer mounts netbird state volume" {
	enable_proxy_peer "$COMPOSE_DIR" "myapp-sandbox-proxy-peer"
	yq -e '.services."proxy-peer".volumes[] | select(. == "netbird-proxy-peer-state:/var/lib/netbird")' \
		"$COMPOSE_DIR/sandcat/compose-proxy-peer.yml"
	yq -e '.volumes | has("netbird-proxy-peer-state")' \
		"$COMPOSE_DIR/sandcat/compose-proxy-peer.yml"
}

@test "enable_proxy_peer does not hardcode peer-proxy" {
	enable_proxy_peer "$COMPOSE_DIR" "myapp-sandbox-proxy-peer"
	run grep -R "peer-proxy" "$COMPOSE_DIR/sandcat/compose-proxy-peer.yml" || true
	assert_output ""
}

@test "enable_proxy_peer adds NB_API_TOKEN passthrough" {
	enable_proxy_peer "$COMPOSE_DIR" "myapp-sandbox-proxy-peer"

	yq -e '.services."proxy-peer".environment[] | select(. == "NB_API_TOKEN")' \
		"$COMPOSE_DIR/sandcat/compose-proxy-peer.yml"
}

@test "enable_proxy_peer fails when peer name argument is empty" {
	run enable_proxy_peer "$COMPOSE_DIR" ""
	assert_failure
	assert_output --partial "peer name"
}

#!/usr/bin/env bats

setup() {
	load test_helper
	EXAMPLE="$SCT_ROOT/../docs/examples/proxy-peer"
}

@test "compose-proxy-peer interpolates NB_SETUP_KEY" {
	run grep -F 'NB_SETUP_KEY=${NB_SETUP_KEY}' "$EXAMPLE/compose-proxy-peer.yml"
	assert_success
}

@test "compose-proxy-peer has no hardcoded nbp_ token" {
	run grep -E 'nbp_|[0-9A-F]{8}-[0-9A-F]{4}' "$EXAMPLE/compose-proxy-peer.yml"
	assert_failure
}

@test "compose-proxy-peer does not mount sandcat user settings" {
	run grep -F 'settings.json' "$EXAMPLE/compose-proxy-peer.yml"
	assert_failure
}

@test "example ships .env.example and gitignores .env" {
	[[ -f "$EXAMPLE/.env.example" ]]
	run grep -F 'docs/examples/proxy-peer/.env' "$SCT_ROOT/../.gitignore"
	assert_success
}

@test "example has no capability-catalog.json" {
	[[ ! -f "$EXAMPLE/capability-catalog.json" ]]
}

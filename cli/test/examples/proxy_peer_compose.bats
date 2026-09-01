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

@test "proxy-peer README documents two-env-file compose command" {
	run grep -F 'docker compose --env-file netbird.env --env-file .env -f compose-proxy-peer.yml up -d --build' \
		"$EXAMPLE/README.md"
	assert_success
}

@test "proxy-peer README does not mention capability-runtime or sandcat netbird" {
	run grep -Ei 'capability-runtime|sandcat netbird|sandcat capability|--capability' \
		"$EXAMPLE/README.md"
	assert_failure
}

@test "proxy-peer README includes mermaid data path" {
	run grep -F 'flowchart LR' "$EXAMPLE/README.md"
	assert_success
}

@test "settings-proxy-peer.json does not mention capability-runtime" {
	run grep -F 'capability-runtime' "$EXAMPLE/settings-proxy-peer.json"
	assert_failure
}

@test "cli README has no Capability sidecar heading" {
	run grep -F '## Capability sidecar' "$SCT_ROOT/README.md"
	assert_failure
}

@test "tracked superpowers netbird plans are not in the tree" {
	[[ ! -f "$SCT_ROOT/../docs/superpowers/plans/2026-06-15-netbird-dynamic-wireguard.md" ]]
}

#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/netbird.bash"
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/sandcat"
	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/.sandcat"
	cd "$PROJECT_DIR" || return 1
}

teardown() {
	unstub_all
}

@test "netbird_flatten_secret_setting returns empty for empty and null" {
	run netbird_flatten_secret_setting ""
	assert_success
	assert_output ""
	run netbird_flatten_secret_setting "null"
	assert_success
	assert_output ""
}

@test "netbird_flatten_secret_setting returns JSON strings as-is" {
	run netbird_flatten_secret_setting '"nbp_x"'
	assert_success
	assert_output "nbp_x"
}

@test "netbird_flatten_secret_setting keeps digit-only JSON strings" {
	run netbird_flatten_secret_setting '"0123456789"'
	assert_success
	assert_output "0123456789"
}

@test "netbird_flatten_secret_setting keeps boolean-looking JSON strings" {
	run netbird_flatten_secret_setting '"true"'
	assert_success
	assert_output "true"
}

@test "export_netbird_compose_env keeps a digit-only API token from user settings" {
	printf '%s\n' '{"netbird_api_token":"0123456789"}' >"$HOME/.config/sandcat/settings.json"
	unset NB_API_TOKEN
	export_netbird_compose_env
	[[ "$NB_API_TOKEN" == "0123456789" ]]
}

@test "netbird_flatten_secret_setting unwraps op object" {
	run netbird_flatten_secret_setting '{"op":"op://Vault/Item/credential"}'
	assert_success
	assert_output "op://Vault/Item/credential"
}

@test "netbird_flatten_secret_setting unwraps pass object" {
	run netbird_flatten_secret_setting '{"pass":"pass://Vault/Item/password"}'
	assert_success
	assert_output "pass://Vault/Item/password"
}

@test "netbird_flatten_secret_setting unwraps value object" {
	run netbird_flatten_secret_setting '{"value":"nbp_plain"}'
	assert_success
	assert_output "nbp_plain"
}

@test "netbird_flatten_secret_setting fails when both value and op are set" {
	run netbird_flatten_secret_setting '{"value":"k","op":"op://x"}'
	assert_failure
	assert_output --partial "exactly one of"
}

@test "export_netbird_compose_env flattens object api token to NB_API_TOKEN" {
	echo '{"netbird_api_token":{"op":"op://Vault/Item/credential"}}' > "$HOME/.config/sandcat/settings.json"
	unset NB_API_TOKEN
	export_netbird_compose_env
	[[ "$NB_API_TOKEN" == "op://Vault/Item/credential" ]]
}

@test "export_netbird_compose_env flattens object enrollment key to NB_SETUP_KEY" {
	echo '{"netbird_enrollment_key":{"pass":"pass://V/I/password"}}' > "$HOME/.config/sandcat/settings.json"
	unset NB_SETUP_KEY
	export_netbird_compose_env
	[[ "$NB_SETUP_KEY" == "pass://V/I/password" ]]
}

@test "export_netbird_compose_env still exports literal string tokens" {
	echo '{"netbird_api_token":"api-token-456"}' > "$HOME/.config/sandcat/settings.json"
	unset NB_API_TOKEN
	export_netbird_compose_env
	[[ "$NB_API_TOKEN" == "api-token-456" ]]
}

@test "export_netbird_compose_env does not invoke op" {
	echo '{"netbird_api_token":{"op":"op://Vault/Item/credential"}}' > "$HOME/.config/sandcat/settings.json"
	unset NB_API_TOKEN
	# require.bash defines a yq() function, so `command -v yq` is the function
	# name — use type -P for the real binary. Keep that dir on PATH while
	# dropping any `op` so a mistaken resolve would fail loudly.
	local yq_bin yq_dir
	yq_bin=$(type -P yq)
	[[ -n "$yq_bin" ]]
	yq_dir=$(dirname "$yq_bin")
	PATH="$yq_dir:/usr/bin:/bin"
	export_netbird_compose_env
	[[ "$NB_API_TOKEN" == "op://Vault/Item/credential" ]]
}

@test "export_netbird_compose_env ignores a project-only API token" {
	printf '%s\n' '{}' >"$HOME/.config/sandcat/settings.json"
	printf '%s\n' '{"netbird_api_token":"project-token"}' >"$PROJECT_DIR/.sandcat/settings.json"
	unset NB_API_TOKEN
	export_netbird_compose_env
	[[ -z "${NB_API_TOKEN:-}" ]]
}

@test "prepare_agent_sandcat_mount strips NetBird secrets and keeps other keys" {
	mkdir -p "$PROJECT_DIR/.sandcat"
	printf '%s\n' '{"netbird_api_token":"tok","netbird_enrollment_key":"key","network":[{"action":"allow"}]}' \
		>"$PROJECT_DIR/.sandcat/settings.json"
	printf '%s\n' '{"netbird_api_token":"local-tok","env":{"FOO":"bar"}}' \
		>"$PROJECT_DIR/.sandcat/settings.local.json"
	local dest="$BATS_TEST_TMPDIR/filtered"
	prepare_agent_sandcat_mount "$PROJECT_DIR/.sandcat" "$dest"
	run yq -r '.netbird_api_token' "$dest/settings.json"
	assert_output "null"
	run yq -r '.netbird_enrollment_key' "$dest/settings.json"
	assert_output "null"
	run yq -r '.network[0].action' "$dest/settings.json"
	assert_output "allow"
	run yq -r '.netbird_api_token' "$dest/settings.local.json"
	assert_output "null"
	run yq -r '.env.FOO' "$dest/settings.local.json"
	assert_output "bar"
}

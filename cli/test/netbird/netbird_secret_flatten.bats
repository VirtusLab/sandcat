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
	PATH="/usr/local/bin:/usr/bin:/bin"
	export_netbird_compose_env
	[[ "$NB_API_TOKEN" == "op://Vault/Item/credential" ]]
}

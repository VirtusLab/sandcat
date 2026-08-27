#!/usr/bin/env bats

setup() {
	load test_helper
	source "$SCT_LIBDIR/netbird.bash"
	export HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$HOME/.config/sandcat"
	PROJECT_DIR="$BATS_TEST_TMPDIR/project"
	mkdir -p "$PROJECT_DIR/.sandcat"
	cd "$PROJECT_DIR" || return 1
	SETTINGS="$PROJECT_DIR/.sandcat/settings.json"
}

teardown() {
	unstub_all
}

@test "netbird_default_peer_name_proxy uses compose project formula" {
	run netbird_default_peer_name_proxy "myapp-sandbox"
	assert_success
	assert_output "myapp-sandbox-proxy"
}

@test "netbird_ensure_peer_name_settings writes proxy default when key absent" {
	echo '{}' >"$SETTINGS"
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"

	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "myapp-sandbox-proxy"
	run grep -F 'netbird_peer_name_proxy_peer' "$SETTINGS"
	assert_failure
}

@test "netbird_ensure_peer_name_settings refills empty string keys" {
	cat >"$SETTINGS" <<'JSON'
{"netbird_peer_name_proxy": ""}
JSON
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"

	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "myapp-sandbox-proxy"
}

@test "netbird_ensure_peer_name_settings preserves non-empty overrides" {
	cat >"$SETTINGS" <<'JSON'
{"netbird_peer_name_proxy": "custom-proxy"}
JSON
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"

	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "custom-proxy"
}

@test "netbird_ensure_peer_name_settings creates settings file when missing" {
	rm -f "$SETTINGS"
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"
	[[ -f "$SETTINGS" ]]
	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "myapp-sandbox-proxy"
}

@test "netbird_apply_peer_names_to_catalog sets peer_hostname on cap-reach-api" {
	local catalog="$BATS_TEST_TMPDIR/capability-catalog.json"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/capability-catalog.json" "$catalog"

	netbird_apply_peer_names_to_catalog "$catalog" "myapp-sandbox-proxy"

	run yq -r '.capabilities[] | select(.ref == "cap-reach-api") | .peer_hostname' "$catalog"
	assert_output "myapp-sandbox-proxy"
	run yq '[.capabilities[] | select(.ref == "cap-reach-proxy")] | length' "$catalog"
	assert_output "0"
}

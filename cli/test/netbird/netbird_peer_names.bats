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

@test "netbird_default_peer_name_proxy_peer uses compose project formula" {
	run netbird_default_peer_name_proxy_peer "myapp-sandbox"
	assert_success
	assert_output "myapp-sandbox-proxy-peer"
}

@test "netbird_peer_fqdn joins name and domain" {
	run netbird_peer_fqdn "myapp-sandbox-proxy-peer" "netbird.selfhosted"
	assert_success
	assert_output "myapp-sandbox-proxy-peer.netbird.selfhosted"
}

@test "netbird_ensure_peer_name_settings writes defaults when keys absent" {
	echo '{}' >"$SETTINGS"
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"

	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "myapp-sandbox-proxy"
	run yq -r '.netbird_peer_name_proxy_peer' "$SETTINGS"
	assert_output "myapp-sandbox-proxy-peer"
}

@test "netbird_ensure_peer_name_settings refills empty string keys" {
	cat >"$SETTINGS" <<'JSON'
{"netbird_peer_name_proxy": "", "netbird_peer_name_proxy_peer": ""}
JSON
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"

	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "myapp-sandbox-proxy"
	run yq -r '.netbird_peer_name_proxy_peer' "$SETTINGS"
	assert_output "myapp-sandbox-proxy-peer"
}

@test "netbird_ensure_peer_name_settings preserves non-empty overrides" {
	cat >"$SETTINGS" <<'JSON'
{"netbird_peer_name_proxy": "custom-proxy", "netbird_peer_name_proxy_peer": "custom-proxy-peer"}
JSON
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"

	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "custom-proxy"
	run yq -r '.netbird_peer_name_proxy_peer' "$SETTINGS"
	assert_output "custom-proxy-peer"
}

@test "netbird_ensure_peer_name_settings creates settings file when missing" {
	rm -f "$SETTINGS"
	netbird_ensure_peer_name_settings "$SETTINGS" "myapp-sandbox"
	[[ -f "$SETTINGS" ]]
	run yq -r '.netbird_peer_name_proxy' "$SETTINGS"
	assert_output "myapp-sandbox-proxy"
}

@test "netbird_apply_peer_names_to_catalog sets peer_hostname and dns_label" {
	local catalog="$BATS_TEST_TMPDIR/capability-catalog.json"
	cp "$SCT_TEMPLATEDIR/devcontainer/sandcat/capability-catalog.json" "$catalog"

	netbird_apply_peer_names_to_catalog \
		"$catalog" "myapp-sandbox-proxy" "myapp-sandbox-proxy-peer" "netbird.selfhosted"

	run yq -r '.capabilities[] | select(.ref == "cap-reach-api") | .peer_hostname' "$catalog"
	assert_output "myapp-sandbox-proxy"
	run yq -r '.capabilities[] | select(.ref == "cap-reach-proxy") | .dns_label' "$catalog"
	assert_output "myapp-sandbox-proxy-peer.netbird.selfhosted"
}

@test "netbird_apply_peer_names_to_layer1_example sets allow host FQDN" {
	local example="$BATS_TEST_TMPDIR/settings.proxy-peer.example.json"
	cp "$SCT_TEMPLATEDIR/settings-proxy-peer.json" "$example"

	netbird_apply_peer_names_to_layer1_example \
		"$example" "myapp-sandbox-proxy-peer" "netbird.selfhosted"

	run yq -r '.network[] | select(.action == "allow") | .host' "$example"
	assert_output "myapp-sandbox-proxy-peer.netbird.selfhosted"
}

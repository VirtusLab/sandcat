#!/usr/bin/env bats

setup() {
	load "$BATS_TEST_DIRNAME/../composefile/test_helper"

	SCRIPT="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/netbird-peer-lifecycle.sh"
	# shellcheck source=/dev/null
	source "$SCRIPT"

	export NB_PEER_NAME="myapp-sandbox-proxy"
	export NB_MANAGEMENT_URL="http://mgmt.test:33073"
	export NETBIRD_STATE_ROOT="$BATS_TEST_TMPDIR/var-lib-netbird"
	export NETBIRD_SETTINGS_PATH="$BATS_TEST_TMPDIR/settings.json"
	unset NB_API_TOKEN
}

teardown() {
	unstub_all
}

@test "local state causes reconnect without a management request" {
	mkdir -p "$NETBIRD_STATE_ROOT"
	printf '{}\n' >"$NETBIRD_STATE_ROOT/config.json"

	run netbird_replace_same_name_peer_if_needed

	assert_success
	assert_output --partial "reconnect"
}

@test "0.72 enrolled default.json reconnects without a management request" {
	mkdir -p "$NETBIRD_STATE_ROOT"
	printf '{}\n' >"$NETBIRD_STATE_ROOT/default.json"
	stub netbird "status --json : echo '{\"status\":\"Connected\"}'"

	run netbird_replace_same_name_peer_if_needed

	assert_success
	assert_output --partial "reconnect"
}

@test "0.72 NeedsLogin default.json is not enrolled local state" {
	mkdir -p "$NETBIRD_STATE_ROOT"
	printf '{}\n' >"$NETBIRD_STATE_ROOT/default.json"
	export NB_API_TOKEN="tok"
	stub netbird "status --json : echo '{\"status\":\"NeedsLogin\"}'"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"abc\",\"name\":\"myapp-sandbox-proxy\"}]'" \
		"-sf --max-time 10 -X DELETE -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers/abc : :"

	run netbird_replace_same_name_peer_if_needed

	assert_success
	assert_output --partial "replace"
}

@test "missing local state replaces an existing peer" {
	export NB_API_TOKEN="tok"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"abc\",\"name\":\"myapp-sandbox-proxy\"}]'" \
		"-sf --max-time 10 -X DELETE -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers/abc : :"

	run netbird_replace_same_name_peer_if_needed

	assert_success
	assert_output --partial "replace"
}

@test "replacement skips when the API token is missing" {
	run netbird_replace_same_name_peer_if_needed

	assert_success
	assert_output --partial "skipping same-name peer check"
}

@test "netbird_mgmt_delete_peer_by_name deletes matched peer by id" {
	export NB_API_TOKEN="tok"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"abc\",\"name\":\"myapp-sandbox-proxy\"}]'" \
		"-sf --max-time 10 -X DELETE -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers/abc : :"

	run netbird_mgmt_delete_peer_by_name "myapp-sandbox-proxy"

	assert_success
}

@test "replacement fails when multiple management peers match the name" {
	export NB_API_TOKEN="tok"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"abc\",\"name\":\"myapp-sandbox-proxy\"},{\"id\":\"def\",\"hostname\":\"MYAPP-SANDBOX-PROXY\"}]'"

	run netbird_replace_same_name_peer_if_needed

	assert_failure
	assert_output --partial "multiple management peers"
}

@test "peer lookup matches name hostname and dns_label case-insensitively" {
	export NB_API_TOKEN="tok"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"by-name\",\"name\":\"NAME-TARGET\"},{\"id\":\"by-hostname\",\"hostname\":\"Hostname-Target\"},{\"id\":\"by-label\",\"dns_label\":\"label-target\"}]'" \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"by-name\",\"name\":\"NAME-TARGET\"},{\"id\":\"by-hostname\",\"hostname\":\"Hostname-Target\"},{\"id\":\"by-label\",\"dns_label\":\"label-target\"}]'" \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"by-name\",\"name\":\"NAME-TARGET\"},{\"id\":\"by-hostname\",\"hostname\":\"Hostname-Target\"},{\"id\":\"by-label\",\"dns_label\":\"label-target\"}]'"

	lookup_all_peer_names() {
		netbird_mgmt_find_peer_id_by_name "name-target"
		netbird_mgmt_find_peer_id_by_name "hostname-target"
		netbird_mgmt_find_peer_id_by_name "LABEL-TARGET"
	}
	run lookup_all_peer_names

	assert_success
	assert_output $'by-name\nby-hostname\nby-label'
}

@test "dns_label update uses the local peer FQDN" {
	export NB_API_TOKEN="tok"
	stub netbird \
		"status --json : echo '{\"fqdn\":\"myapp-sandbox-proxy-100-64-0-5.netbird.selfhosted\"}'"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"abc\",\"fqdn\":\"myapp-sandbox-proxy-100-64-0-5.netbird.selfhosted\"}]'" \
		"-sf --max-time 10 -X PUT -H 'Authorization: Token tok' -H 'Content-Type: application/json' -d '{\"dns_label\":\"myapp-sandbox-proxy\"}' http://mgmt.test:33073/api/peers/abc : echo '{\"fqdn\":\"myapp-sandbox-proxy.netbird.selfhosted\"}'"

	run netbird_set_dns_label

	assert_success
	assert_output --partial "dns_label set"
}

@test "dns_label update soft-skips without an API token" {
	run netbird_set_dns_label

	assert_success
	assert_output --partial "skipping dns_label"
}

@test "dns_label update requires an explicit peer name" {
	unset NB_PEER_NAME

	run netbird_set_dns_label

	assert_failure
	assert_output --partial "NB_PEER_NAME"
}

@test "netbird_resolve_secret_ref leaves plaintext unchanged" {
	run netbird_resolve_secret_ref "nbp_plain"
	assert_success
	assert_output "nbp_plain"
}

@test "netbird_resolve_secret_ref uses op read for op:// refs" {
	stub timeout "60 op read op://Vault/x/credential : echo resolved-token"
	run netbird_resolve_secret_ref "op://Vault/x/credential"
	assert_success
	assert_output "resolved-token"
}

@test "netbird_resolve_secret_ref logs into pass-cli once for two pass:// refs" {
	stub pass-cli \
		"login : :" \
		"info : echo '  - Personal Access Token: pst_test'"
	stub timeout \
		"60 pass-cli vault list : :" \
		"60 pass-cli item view pass://Vault/Item/password : echo secret-a" \
		"60 pass-cli item view pass://Vault/Other/password : echo secret-b"
	run bash -c '
		source "$1"
		netbird_resolve_secret_ref "pass://Vault/Item/password"
		echo ---
		netbird_resolve_secret_ref "pass://Vault/Other/password"
	' _ "$SCRIPT"
	assert_success
	assert_output $'secret-a\n---\nsecret-b'
}

@test "netbird_resolve_secret_ref retries pass-cli item view after warmup" {
	stub pass-cli \
		"login : :" \
		"info : echo '  - Personal Access Token: pst_test'"
	stub timeout \
		"60 pass-cli vault list : :" \
		"60 pass-cli item view pass://Vault/Item/password : exit 1" \
		"60 pass-cli item view pass://Vault/Item/password : echo secret-a"
	run netbird_resolve_secret_ref "pass://Vault/Item/password"
	assert_success
	assert_output "secret-a"
}

@test "pass-cli login rejects non-PAT session" {
	stub pass-cli \
		"login : :" \
		"info : echo 'ID: user@example.com'" \
		"logout : :"
	run netbird_pass_cli_login_once
	assert_failure
	assert_output --partial "not a Personal Access Token"
}

@test "netbird_prepare_enroll_credentials resolves NB_API_TOKEN before replace" {
	export NB_API_TOKEN="op://Vault/x/credential"
	export NB_SETUP_KEY="setup-literal"
	stub timeout "60 op read op://Vault/x/credential : echo tok"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[]'"
	netbird_prepare_enroll_credentials
	run netbird_replace_same_name_peer_if_needed
	assert_success
}

@test "netbird_prepare_enroll_credentials flattens object enrollment key from settings" {
	unset NB_SETUP_KEY
	unset NB_API_TOKEN
	printf '%s\n' '{"netbird_enrollment_key":{"op":"op://Vault/x/credential"}}' >"$NETBIRD_SETTINGS_PATH"
	stub timeout "60 op read op://Vault/x/credential : echo nbp_resolved"
	netbird_prepare_enroll_credentials
	[[ "$NB_SETUP_KEY" == "nbp_resolved" ]]
}

@test "netbird_resolve_api_token flattens object-shaped token from settings" {
	unset NB_API_TOKEN
	printf '%s\n' '{"netbird_api_token":{"value":"nbp_from_settings"}}' >"$NETBIRD_SETTINGS_PATH"
	run netbird_resolve_api_token
	assert_success
	assert_output "nbp_from_settings"
}

@test "netbird_resolve_api_token resolves op:// from object-shaped settings" {
	unset NB_API_TOKEN
	printf '%s\n' '{"netbird_api_token":{"op":"op://Vault/x/credential"}}' >"$NETBIRD_SETTINGS_PATH"
	stub timeout "60 op read op://Vault/x/credential : echo tok"
	run netbird_resolve_api_token
	assert_success
	assert_output "tok"
}

@test "replacement skips when settings token is an empty object" {
	unset NB_API_TOKEN
	printf '%s\n' '{"netbird_api_token":{}}' >"$NETBIRD_SETTINGS_PATH"
	run netbird_replace_same_name_peer_if_needed
	assert_success
	assert_output --partial "skipping same-name peer check"
}

@test "mitmproxy-init aborts start_netbird when same-name replace fails" {
	local init="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"
	run awk '/^start_netbird\(\)/,/^}/' "$init"
	assert_success
	assert_output --partial "netbird_replace_same_name_peer_if_needed || return 1"
	refute_output --partial "continuing with netbird up"
}

@test "proxy-peer-init aborts start_netbird when same-name replace fails" {
	local init="$SCT_ROOT/../docs/examples/proxy-peer/scripts/proxy-peer-init.sh"
	run awk '/^start_netbird\(\)/,/^}/' "$init"
	assert_success
	assert_output --partial "netbird_replace_same_name_peer_if_needed || return 1"
	refute_output --partial "continuing with netbird up"
}

@test "example does not keep a second lifecycle script" {
	[[ ! -f "$SCT_ROOT/../docs/examples/proxy-peer/scripts/netbird-peer-lifecycle.sh" ]]
}

@test "supervise_netbird_daemon re-enroll prepares credentials" {
	local init="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"
	run awk '/^supervise_netbird_daemon\(\)/,/^}/' "$init"
	assert_success
	assert_output --partial "netbird_prepare_enroll_credentials"
	refute_output --partial "netbird_replace_same_name_peer_if_needed || true"
}

@test "proxy-peer supervise_netbird_daemon re-enroll prepares credentials" {
	local init="$SCT_ROOT/../docs/examples/proxy-peer/scripts/proxy-peer-init.sh"
	run awk '/^supervise_netbird_daemon\(\)/,/^}/' "$init"
	assert_success
	assert_output --partial "netbird_prepare_enroll_credentials"
	refute_output --partial "netbird_replace_same_name_peer_if_needed || true"
}

@test "mitmproxy-init does not copy enrollment key into NB_SETUP_KEY with raw jq" {
	local init="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh"
	# Raw jq dumps object JSON into env and skips prepare's flatten-if-empty path.
	run grep -F "NB_SETUP_KEY=\$(jq -r '.netbird_enrollment_key" "$init"
	assert_failure
}

@test "prepare profile converts string ManagementURL to a Go url.URL object" {
	# NetBird 0.72 Config.ManagementURL is *url.URL; a JSON string crashes the
	# daemon with "cannot unmarshal string into Go struct field Config.ManagementURL".
	mkdir -p "$NETBIRD_STATE_ROOT"
	printf '%s\n' '{"ManagementURL":"http://192.0.2.1:33073","AdminURL":"http://192.0.2.1:33073","PrivateKey":"keep-me"}' \
		>"$NETBIRD_STATE_ROOT/default.json"
	export NB_MANAGEMENT_URL="http://192.0.2.1:33073"
	export NETBIRD_IFACE="wt0"

	netbird_prepare_local_management_profile

	run jq -c '{scheme:.ManagementURL.Scheme, host:.ManagementURL.Host, key:.PrivateKey, admin:.AdminURL.Scheme}' \
		"$NETBIRD_STATE_ROOT/default.json"
	assert_success
	assert_output '{"scheme":"http","host":"192.0.2.1:33073","key":"keep-me","admin":"http"}'
}

@test "prepare profile does not seed a missing default.json" {
	# 0.72 writes native url.URL objects; seeding a string profile is what broke
	# the daemon. Leave a missing file to the client.
	export NB_MANAGEMENT_URL="http://192.0.2.1:33073"

	netbird_prepare_local_management_profile

	[[ ! -e "$NETBIRD_STATE_ROOT/default.json" ]]
}

@test "init scripts do not seed ManagementURL as a JSON string" {
	run grep -F '"ManagementURL": "$mgmt_url"' \
		"$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy-init.sh" \
		"$SCT_ROOT/../docs/examples/proxy-peer/scripts/proxy-peer-init.sh"
	assert_failure
}

@test "prepare profile coerces leftover hostname string URLs without rewriting" {
	mkdir -p "$NETBIRD_STATE_ROOT"
	printf '%s\n' '{"ManagementURL":"http://host.docker.internal:33073","AdminURL":"http://host.docker.internal:33073","PrivateKey":"keep-me"}' \
		>"$NETBIRD_STATE_ROOT/default.json"
	export NB_MANAGEMENT_URL="http://host.docker.internal:33073"

	netbird_prepare_local_management_profile

	run jq -c '{host:.ManagementURL.Host, key:.PrivateKey}' "$NETBIRD_STATE_ROOT/default.json"
	assert_success
	assert_output '{"host":"host.docker.internal:33073","key":"keep-me"}'
}

@test "prepare profile refreshes an existing object URL from NB_MANAGEMENT_URL" {
	mkdir -p "$NETBIRD_STATE_ROOT"
	printf '%s\n' '{"ManagementURL":{"Scheme":"http","Host":"192.0.2.8:33073","Path":""},"AdminURL":{"Scheme":"http","Host":"192.0.2.8:33073","Path":""},"WgIface":"wt0","PrivateKey":"keep-me"}' \
		>"$NETBIRD_STATE_ROOT/default.json"
	export NB_MANAGEMENT_URL="http://192.0.2.1:33073"
	export NETBIRD_IFACE="wt0"
	export NETBIRD_WG_PORT="51821"

	netbird_prepare_local_management_profile

	run jq -c '{host:.ManagementURL.Host, port:.WgPort, iface:.WgIface, key:.PrivateKey}' \
		"$NETBIRD_STATE_ROOT/default.json"
	assert_success
	assert_output '{"host":"192.0.2.1:33073","port":51821,"iface":"wt0","key":"keep-me"}'
}

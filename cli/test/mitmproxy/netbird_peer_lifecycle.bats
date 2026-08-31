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

@test "missing local state replaces an existing peer" {
	export NB_API_TOKEN="tok"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[{\"id\":\"abc\",\"name\":\"myapp-sandbox-proxy\"}]'" \
		"-sf --max-time 10 -X DELETE -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers/abc : :"

	run netbird_replace_same_name_peer_if_needed

	assert_success
	assert_output --partial "replace"
}

@test "replacement fails loudly when the API token is missing" {
	run netbird_replace_same_name_peer_if_needed

	assert_failure
	assert_output --partial "netbird_api_token"
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
	stub op "read op://Vault/x/credential : echo resolved-token"
	run netbird_resolve_secret_ref "op://Vault/x/credential"
	assert_success
	assert_output "resolved-token"
}

@test "netbird_resolve_secret_ref logs into pass-cli once for two pass:// refs" {
	stub pass-cli \
		"login : :" \
		"item view pass://Vault/Item/password : echo secret-a" \
		"item view pass://Vault/Other/password : echo secret-b"
	run bash -c '
		source "$1"
		netbird_resolve_secret_ref "pass://Vault/Item/password"
		echo ---
		netbird_resolve_secret_ref "pass://Vault/Other/password"
	' _ "$SCRIPT"
	assert_success
	assert_output $'secret-a\n---\nsecret-b'
}

@test "netbird_prepare_enroll_credentials resolves NB_API_TOKEN before replace" {
	export NB_API_TOKEN="op://Vault/x/credential"
	export NB_SETUP_KEY="setup-literal"
	stub op "read op://Vault/x/credential : echo tok"
	stub curl \
		"-sf --max-time 10 -H 'Authorization: Token tok' http://mgmt.test:33073/api/peers : echo '[]'"
	netbird_prepare_enroll_credentials
	run netbird_replace_same_name_peer_if_needed
	assert_success
}

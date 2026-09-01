#!/usr/bin/env bats
#
# Verifies the contract that the mitmproxy addon and wg-client agree on the
# `dns.conf` filename, and that compose-proxy.yml mounts the shared volume at
# both the addon's write target and wg-client's read target.
#

setup() {
	load test_helper
	ADDON="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/mitmproxy_addon_common.py"
	APP_INIT="$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/app-init.sh"
	COMPOSE="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
	COMPOSE_AGENT="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-agent.yml"
}

# Extract the first double-quoted string from the line in $1 that begins with
# the literal prefix $2. Used to read the dns.conf path from each side of the
# producer/consumer pair so the parsing rule lives in one place.
extract_quoted_value() {
	local file="$1" prefix_pattern="$2"
	grep -E "$prefix_pattern" "$file" | sed -E 's/.*"([^"]+)".*/\1/'
}

addon_dns_conf_path() {
	extract_quoted_value "$ADDON" '^SANDCAT_DNS_CONF_PATH = '
}

wg_dns_conf_path() {
	extract_quoted_value "$WG_CLIENT_INIT" '^DNS_CONF='
}

@test "addon and wg-client agree on the dns.conf basename" {
	local addon_path wg_path
	addon_path=$(addon_dns_conf_path)
	wg_path=$(wg_dns_conf_path)

	[[ -n "$addon_path" ]]
	[[ -n "$wg_path" ]]
	assert_equal "$(basename "$addon_path")" "$(basename "$wg_path")"
}

@test "compose-proxy.yml mounts mitmproxy-config at the addon's write directory" {
	local addon_dir
	addon_dir=$(dirname "$(addon_dns_conf_path)")

	addon_dir="$addon_dir" yq -e "
		.services.mitmproxy.volumes[] |
		select(. == \"mitmproxy-config:\" + env(addon_dir))
	" "$COMPOSE"
}

@test "compose-proxy.yml mounts mitmproxy-config at wg-client's read directory" {
	local wg_dir
	wg_dir=$(dirname "$(wg_dns_conf_path)")

	wg_dir="$wg_dir" yq -e "
		.services.\"wg-client\".volumes[] |
		select(. == \"mitmproxy-config:\" + env(wg_dir) + \":ro\")
	" "$COMPOSE"
}

@test "wg-client and app-init agree on the shared resolv.conf path" {
	local wg_path app_path
	wg_path=$(extract_quoted_value "$WG_CLIENT_INIT" '^SHARED_RESOLV_CONF=')
	app_path=$(extract_quoted_value "$APP_INIT" '^SHARED_RESOLV_CONF=')

	[[ -n "$wg_path" ]]
	[[ -n "$app_path" ]]
	assert_equal "$wg_path" "$app_path"
}

@test "wg-runtime is mounted writable in wg-client and read-only in agent at the shared dir" {
	local shared_dir
	shared_dir=$(dirname "$(extract_quoted_value "$WG_CLIENT_INIT" '^SHARED_RESOLV_CONF=')")

	shared_dir="$shared_dir" yq -e "
		.services.\"wg-client\".volumes[] |
		select(. == \"wg-runtime:\" + env(shared_dir))
	" "$COMPOSE"

	shared_dir="$shared_dir" yq -e "
		.services.agent.volumes[] |
		select(. == \"wg-runtime:\" + env(shared_dir) + \":ro\")
	" "$COMPOSE_AGENT"
}

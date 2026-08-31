#!/usr/bin/env bash

# shellcheck source=constants.bash
source "${BASH_SOURCE%/*}/constants.bash"
# shellcheck source=path.bash
source "${BASH_SOURCE%/*}/path.bash"
# shellcheck source=logging.bash
source "${BASH_SOURCE%/*}/logging.bash"
# shellcheck source=require.bash
source "${BASH_SOURCE%/*}/require.bash"

# Reads a NetBird setting from sandcat settings layers. Later layers win when
# non-empty (user < project < project local), matching mitmproxy addon precedence.
# Args:
#   $1 - settings key (e.g. netbird_api_token)
netbird_read_setting() {
	local key=$1
	require yq

	local value=""
	local file layer_value repo_root

	local -a layers=()
	layers+=("$(sct_home)/settings.json")
	if repo_root=$(find_repo_root 2>/dev/null); then
		layers+=("$repo_root/$SCT_PROJECT_DIR/settings.json")
		layers+=("$repo_root/$SCT_PROJECT_DIR/settings.local.json")
	fi

	for file in "${layers[@]}"; do
		[[ -f "$file" ]] || continue
		layer_value=$(yq -r ".$key // \"\"" "$file")
		if [[ -n "$layer_value" ]]; then
			value="$layer_value"
		fi
	done

	printf '%s' "$value"
}

netbird_default_peer_name_proxy() {
	local project_name=$1
	printf '%s-proxy' "$project_name"
}

# Fills netbird_peer_name_proxy when absent or empty.
# Does not overwrite non-empty values (operator overrides).
# Args:
#   $1 - path to a JSON settings file (usually .sandcat/settings.json)
#   $2 - compose project name (e.g. myapp-sandbox)
netbird_ensure_peer_name_settings() {
	local settings_file=$1
	local project_name=$2
	require yq

	mkdir -p "$(dirname "$settings_file")"
	[[ -f "$settings_file" ]] || printf '%s\n' '{}' >"$settings_file"

	local proxy
	proxy=$(netbird_default_peer_name_proxy "$project_name")

	proxy="$proxy" yq -i -o json '
		.netbird_peer_name_proxy = (
			.netbird_peer_name_proxy | select(. != null and . != "") // env(proxy)
		)
	' "$settings_file"
}

# Export NB_SETUP_KEY from settings when not already set in the environment.
# Used before docker compose so wg-client receives the enrollment key on create.
export_netbird_compose_env() {
	if [[ -z "${NB_SETUP_KEY:-}" ]]; then
		local enrollment_key
		enrollment_key=$(netbird_read_setting netbird_enrollment_key)
		if [[ -n "$enrollment_key" ]]; then
			export NB_SETUP_KEY="$enrollment_key"
		fi
	fi
	if [[ -z "${NB_API_TOKEN:-}" ]]; then
		local api_token
		api_token=$(netbird_read_setting netbird_api_token)
		if [[ -n "$api_token" ]]; then
			export NB_API_TOKEN="$api_token"
		fi
	fi
}

# Export NB_MANAGEMENT_URL from settings when not already set in environment.
export_netbird_management_url() {
	[[ -n "${NB_MANAGEMENT_URL:-}" ]] && return 0

	local management_url
	management_url=$(netbird_read_setting netbird_management_url)
	if [[ -n "$management_url" ]]; then
		export NB_MANAGEMENT_URL="$management_url"
	fi
}

# Returns the management URL wg-client should use for NetBird enrollment.
# netbird_enrollment_management_url in settings wins when set. Remote URLs pass
# through unchanged. localhost / 127.0.0.1 require an explicit enrollment URL
# (wg-client cannot reach the host via localhost).
# Args:
#   $1 - Host-side management URL (e.g. http://localhost:33073)
netbird_enrollment_management_url_from() {
	local management_url=$1
	local explicit

	explicit=$(netbird_read_setting netbird_enrollment_management_url)
	if [[ -n "$explicit" ]]; then
		printf '%s' "$explicit"
		return 0
	fi

	[[ -n "$management_url" ]] || return 0

	if [[ "$management_url" =~ ^https?://(localhost|127\.0\.0\.1)([:/]|$) ]]; then
		return 0
	fi

	printf '%s' "$management_url"
}

# Prints a literal IPv4 address of the Docker host that containers can dial,
# or nothing when detection fails. Literal IPv4 rather than host.docker.internal
# so netbird_enrollment_url_uses_host_bypass matches and management traffic is
# routed off wg0.
netbird_detect_docker_host_ip() {
	local ip=""
	local iface

	case "$(uname -s)" in
	Darwin)
		for iface in en0 en1; do
			ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
			if [[ -n "$ip" ]]; then
				break
			fi
		done
		;;
	*)
		if command -v ip >/dev/null 2>&1; then
			# Source address the kernel picks for off-link traffic is the
			# host's LAN address, which containers can route to.
			ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*[[:space:]]src[[:space:]]\([0-9.]*\).*/\1/p' | head -n1)
		fi
		;;
	esac

	if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		return 0
	fi
	printf '%s' "$ip"
}

# Returns 0 when the enrollment URL targets the Docker host by literal IPv4 and
# wg-client must bypass wg0 for management traffic.
# Args:
#   $1 - Enrollment management URL
netbird_enrollment_url_uses_host_bypass() {
	local url=$1
	[[ "$url" =~ ^https?://([0-9]{1,3}\.){3}[0-9]{1,3}([:/]|$) ]]
}

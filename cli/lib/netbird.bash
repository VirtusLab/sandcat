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
# netbird_api_token and netbird_enrollment_key skip project layers.
# Args:
#   $1 - settings key (e.g. netbird_api_token)
netbird_read_setting() {
	local key=$1

	local value=""
	local file layer_value repo_root

	local -a layers=()
	layers+=("$(sct_home)/settings.json")
	if ! netbird_setting_is_secret_key "$key"; then
		if repo_root=$(netbird_project_root 2>/dev/null); then
			layers+=("$repo_root/$SCT_PROJECT_DIR/settings.json")
			layers+=("$repo_root/$SCT_PROJECT_DIR/settings.local.json")
		fi
	fi

	for file in "${layers[@]}"; do
		[[ -f "$file" ]] || continue
		grep -q "\"$key\"" "$file" 2>/dev/null || continue
		require yq || return 1
		layer_value=$(yq -r ".$key // \"\"" "$file")
		if [[ -n "$layer_value" ]]; then
			value="$layer_value"
		fi
	done

	printf '%s' "$value"
}

# Enrollment key and API token are operator credentials. Project files are
# cloned with the repo, so those two keys are read from user settings only.
netbird_setting_is_secret_key() {
	local key=$1
	[[ "$key" == "netbird_api_token" || "$key" == "netbird_enrollment_key" ]]
}

# Settings lookup start dir. `sandcat init --path other` exports
# SANDCAT_PROJECT_ROOT so we do not read $PWD's .sandcat.
netbird_project_root() {
	if [[ -n "${SANDCAT_PROJECT_ROOT:-}" ]]; then
		find_repo_root "$SANDCAT_PROJECT_ROOT"
	else
		find_repo_root
	fi
}

# Same layers as netbird_read_setting, but each value is JSON (yq -o json).
# Later non-null layers win. Prints `null` when unset. Keeps JSON string quotes
# so digit-only or boolean-looking tokens are not re-parsed as YAML scalars.
netbird_read_setting_json() {
	local key=$1
	local value="null"
	local file layer_value repo_root
	local -a layers=()
	layers+=("$(sct_home)/settings.json")
	if ! netbird_setting_is_secret_key "$key"; then
		if repo_root=$(netbird_project_root 2>/dev/null); then
			layers+=("$repo_root/$SCT_PROJECT_DIR/settings.json")
			layers+=("$repo_root/$SCT_PROJECT_DIR/settings.local.json")
		fi
	fi
	for file in "${layers[@]}"; do
		[[ -f "$file" ]] || continue
		grep -q "\"$key\"" "$file" 2>/dev/null || continue
		require yq || return 1
		layer_value=$(yq -o json ".$key" "$file")
		layer_value=${layer_value%$'\n'}
		if [[ "$layer_value" != "null" ]]; then
			value="$layer_value"
		fi
	done
	printf '%s' "$value"
}

# Args: $1 JSON (string, object, empty, or null)
# Object must have exactly one of value, op, pass.
netbird_flatten_secret_setting() {
	local json=${1-}
	if [[ -z "$json" || "$json" == "null" ]]; then
		printf ''
		return 0
	fi
	require yq || return 1
	# Parse as JSON so quoted digit-only / boolean-looking strings stay strings.
	# YAML input would type 0123456789 as !!float and abort compose/run.
	local typ
	typ=$(printf '%s' "$json" | yq -p json -r 'type')
	case "$typ" in
	string | !!str | number | !!float | !!int | bool | !!bool)
		printf '%s' "$(printf '%s' "$json" | yq -p json -r '.')"
		return 0
		;;
	object | !!map)
		local n
		n=$(printf '%s' "$json" | yq -p json '[.value, .op, .pass] | map(select(. != null)) | length')
		if [[ "$n" != "1" ]]; then
			echo "netbird secret must specify exactly one of 'value', 'op', or 'pass'" >&2
			return 1
		fi
		printf '%s' "$(printf '%s' "$json" | yq -p json -r '.value // .op // .pass')"
		return 0
		;;
	*)
		echo "netbird secret must be a string or object" >&2
		return 1
		;;
	esac
}

# Always writes netbird_peer_name_proxy as {project}-proxy.
# Committed settings must not choose the name: replace DELETEs that peer.
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
	proxy=$(printf '%s-proxy' "$project_name")

	proxy="$proxy" yq -i -o json '.netbird_peer_name_proxy = env(proxy)' "$settings_file"
}

# Copies project .sandcat to dest and drops enrollment/API secrets so the
# agent bind-mount cannot read them even if they were committed.
# Args:
#   $1 - source .sandcat directory
#   $2 - destination directory (replaced)
prepare_agent_sandcat_mount() {
	local src=$1
	local dest=$2

	[[ -n "$dest" && "$dest" != "/" ]] || return 1
	rm -rf "$dest"
	mkdir -p "$dest"
	[[ -d "$src" ]] || return 0
	if ! cp -a "$src/." "$dest/"; then
		rm -rf "$dest"
		return 1
	fi

	local f
	for f in "$dest/settings.json" "$dest/settings.local.json"; do
		[[ -s "$f" ]] || continue
		if ! require yq || ! yq -i -o json 'del(.netbird_api_token) | del(.netbird_enrollment_key)' "$f"; then
			rm -rf "$dest"
			return 1
		fi
	done
}

# Prepares a filtered .sandcat copy and exports SANDCAT_AGENT_SANDCAT for compose.
export_agent_sandcat_mount() {
	local repo_root src dest
	repo_root=$(netbird_project_root 2>/dev/null) || return 0
	src="$repo_root/$SCT_PROJECT_DIR"
	dest="$(sct_home)/agent-sandcat/${repo_root//\//_}"
	prepare_agent_sandcat_mount "$src" "$dest" || return 1
	write_agent_sandcat_compose_env "$repo_root" "$dest" || return 1
	export SANDCAT_AGENT_SANDCAT="$dest"
}

# Writes SANDCAT_AGENT_SANDCAT into .devcontainer/.env so Dev Containers
# compose interpolation works (initializeCommand cannot export into compose).
write_agent_sandcat_compose_env() {
	local repo_root=$1
	local dest=$2
	local envf tmp
	envf="$repo_root/.devcontainer/.env"
	[[ -d "$(dirname "$envf")" ]] || return 0
	tmp=$(mktemp)
	if [[ -f "$envf" ]]; then
		grep -v '^SANDCAT_AGENT_SANDCAT=' "$envf" >"$tmp" || true
	fi
	printf 'SANDCAT_AGENT_SANDCAT=%s\n' "$dest" >>"$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$envf"
}

# Export NB_SETUP_KEY from settings when not already set in the environment.
# Used before docker compose so wg-client receives the enrollment key on create.
export_netbird_compose_env() {
	if [[ -z "${NB_SETUP_KEY:-}" ]]; then
		local enrollment_key
		enrollment_key=$(netbird_flatten_secret_setting "$(netbird_read_setting_json netbird_enrollment_key)") || return 1
		if [[ -n "$enrollment_key" ]]; then
			export NB_SETUP_KEY="$enrollment_key"
		fi
	fi
	if [[ -z "${NB_API_TOKEN:-}" ]]; then
		local api_token
		api_token=$(netbird_flatten_secret_setting "$(netbird_read_setting_json netbird_api_token)") || return 1
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

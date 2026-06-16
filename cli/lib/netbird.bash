#!/usr/bin/env bash

# shellcheck source=constants.bash
source "${BASH_SOURCE%/*}/constants.bash"
# shellcheck source=path.bash
source "${BASH_SOURCE%/*}/path.bash"
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

# Export NB_SETUP_KEY from settings when not already set in the environment.
# Used before docker compose so wg-client receives the enrollment key on create.
export_netbird_compose_env() {
	[[ -n "${NB_SETUP_KEY:-}" ]] && return 0

	local enrollment_key
	enrollment_key=$(netbird_read_setting netbird_enrollment_key)
	if [[ -n "$enrollment_key" ]]; then
		export NB_SETUP_KEY="$enrollment_key"
	fi
}

# Resolve NB_API_TOKEN from settings when unset. Env always wins.
_ensure_netbird_api_token() {
	[[ -n "${NB_API_TOKEN:-}" ]] && return 0

	local token
	token=$(netbird_read_setting netbird_api_token)
	if [[ -n "$token" ]]; then
		export NB_API_TOKEN="$token"
		return 0
	fi

	echo "netbird_api_token is not set." >&2
	echo "Add it to $(sct_home)/settings.json (or export NB_API_TOKEN)." >&2
	echo "Create a token in the NetBird dashboard under API Keys, then run: sandcat edit user-settings" >&2
	echo "See cli/README.md § Dynamic networking (NetBird) for the full setup." >&2
	return 1
}

# Calls the NetBird management REST API.
# Requires NB_API_TOKEN (env or netbird_api_token in settings).
# NB_MANAGEMENT_URL defaults to https://api.netbird.io.
# Prints the response body on success; writes curl/API errors to stderr.
# Args:
#   $1 - HTTP method (GET, POST, DELETE)
#   $2 - API path (e.g. /api/peers)
#   $3 - Optional JSON body
netbird_api() {
	local method=$1
	local path=$2
	local body=${3:-}

	_ensure_netbird_api_token || return 1

	local url="${NB_MANAGEMENT_URL:-https://api.netbird.io}${path}"
	local -a args=(-sS -f -X "$method"
		-H "Authorization: Token $NB_API_TOKEN"
		-H "Accept: application/json"
		-H "Content-Type: application/json")

	[[ -n "$body" ]] && args+=(-d "$body")

	local response
	if ! response=$(curl "${args[@]}" "$url" 2>&1); then
		echo "NetBird API ${method} ${path} failed: ${response}" >&2
		return 1
	fi

	printf '%s\n' "$response"
}

# Returns the current peer list from the NetBird management server.
netbird_status() {
	netbird_api "GET" "/api/peers"
}

# Adds a network route served by a peer.
# Args:
#   $1 - Network CIDR (e.g. 10.8.0.0/24)
#   $2 - Peer ID that serves the route
netbird_route_add() {
	local network=$1
	local peer_id=$2
	netbird_api "POST" "/api/routes" \
		"{\"network\":\"$network\",\"peer\":\"$peer_id\",\"enabled\":true}"
}

# Removes a network route by ID.
# Args:
#   $1 - Route ID (returned by netbird_route_add)
netbird_route_remove() {
	local route_id=$1
	netbird_api "DELETE" "/api/routes/$route_id"
}

# Removes a peer from the NetBird management server.
# The netbird daemon running in wg-client detects the removal and drops the
# peer from wt0, which removes the route to that endpoint for the agent.
# Args:
#   $1 - Peer ID
netbird_peer_remove() {
	local peer_id=$1
	netbird_api "DELETE" "/api/peers/$peer_id"
}

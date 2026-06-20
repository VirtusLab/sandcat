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
	netbird_sync_local_server_exposed_address
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

# Returns 0 when the enrollment URL targets the Docker host by literal IPv4 and
# wg-client must bypass wg0 for management traffic.
# Args:
#   $1 - Enrollment management URL
netbird_enrollment_url_uses_host_bypass() {
	local url=$1
	[[ "$url" =~ ^https?://([0-9]{1,3}\.){3}[0-9]{1,3}([:/]|$) ]]
}

# Aligns netbird-server exposedAddress with netbird_enrollment_management_url so
# enrolled peers keep dialing the Docker-host IP instead of localhost.
netbird_sync_local_server_exposed_address() {
	local enrollment_url config_file dest_dir current

	enrollment_url=$(netbird_read_setting netbird_enrollment_management_url)
	[[ -n "$enrollment_url" ]] || return 0
	netbird_enrollment_url_uses_host_bypass "$enrollment_url" || return 0

	dest_dir="$(sct_home)/netbird-server"
	config_file="$dest_dir/config.yaml"
	[[ -f "$config_file" ]] || return 0

	require yq
	current=$(yq -r '.server.exposedAddress // ""' "$config_file")
	if [[ "$current" == "$enrollment_url" ]]; then
		return 0
	fi

	NB_EXPOSED="$enrollment_url" \
		yq -i '.server.exposedAddress = strenv(NB_EXPOSED)' "$config_file"
	echo "Updated netbird-server exposedAddress to $enrollment_url." | info
	echo "Restart netbird-server: cd $(sct_home)/netbird-server && docker compose --env-file netbird-server.env up -d --force-recreate netbird-server" | info
}

# Resolves the NetBird embedded-IdP encryption key.
# NETBIRD_ENCRYPTION_KEY env wins; otherwise generates a new key.
_netbird_resolve_encryption_key() {
	if [[ -n "${NETBIRD_ENCRYPTION_KEY:-}" ]]; then
		printf '%s' "$NETBIRD_ENCRYPTION_KEY"
		return 0
	fi

	require openssl
	openssl rand -base64 32
}

# Resolves the relay auth secret for config.yaml server.authSecret.
# NETBIRD_RELAY_AUTH_SECRET env wins; otherwise generates a new secret.
_netbird_resolve_relay_auth_secret() {
	if [[ -n "${NETBIRD_RELAY_AUTH_SECRET:-}" ]]; then
		printf '%s' "$NETBIRD_RELAY_AUTH_SECRET"
		return 0
	fi

	require openssl
	openssl rand -base64 32
}

# Reads a KEY=value from a netbird-server.env file (first match wins).
# Args:
#   $1 - env file path
#   $2 - variable name
_netbird_env_value_from_file() {
	local env_file=$1
	local key=$2
	local line

	[[ -f "$env_file" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "${key}="* ]] || continue
		printf '%s' "${line#"${key}="}"
		return 0
	done <"$env_file"
	return 1
}

# Replaces or appends KEY=value in a simple env file.
# Args:
#   $1 - env file path
#   $2 - variable name
#   $3 - value
_netbird_env_set_value() {
	local env_file=$1
	local key=$2
	local value=$3
	local tmp_file
	local found=false

	[[ -f "$env_file" ]] || return 1
	tmp_file=$(mktemp)
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "${key}="* ]]; then
			printf '%s=%s\n' "$key" "$value"
			found=true
		else
			printf '%s\n' "$line"
		fi
	done <"$env_file" >"$tmp_file"
	if [[ "$found" == false ]]; then
		printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
	fi
	mv "$tmp_file" "$env_file"
}

# Writes secrets and localhost endpoints into the provisioned netbird-server files.
# Args:
#   $1 - provisioned directory (e.g. ~/.config/sandcat/netbird-server)
_netbird_apply_local_server_config() {
	local dest_dir=$1
	local env_file config_file dashboard_file
	local encryption_key relay_secret mgmt_port dashboard_port
	local mgmt_endpoint issuer dashboard_base

	env_file="$dest_dir/netbird-server.env"
	config_file="$dest_dir/config.yaml"
	dashboard_file="$dest_dir/dashboard.env"
	[[ -f "$env_file" && -f "$config_file" ]] || return 0

	encryption_key=$(_netbird_resolve_encryption_key)
	relay_secret=$(_netbird_resolve_relay_auth_secret)
	_netbird_env_set_value "$env_file" NETBIRD_ENCRYPTION_KEY "$encryption_key"
	_netbird_env_set_value "$env_file" NETBIRD_RELAY_AUTH_SECRET "$relay_secret"

	mgmt_port=$(_netbird_env_value_from_file "$env_file" NETBIRD_MGMT_API_PORT || true)
	dashboard_port=$(_netbird_env_value_from_file "$env_file" NETBIRD_DASHBOARD_HTTP_PORT || true)
	mgmt_port=${mgmt_port:-33073}
	dashboard_port=${dashboard_port:-8080}

	mgmt_endpoint="http://localhost:${mgmt_port}"
	issuer="${mgmt_endpoint}/oauth2"
	dashboard_base="http://localhost:${dashboard_port}"

	require yq
	NB_EXPOSED="$mgmt_endpoint" \
		NB_ISSUER="$issuer" \
		NB_NB_AUTH="${dashboard_base}/nb-auth" \
		NB_NB_SILENT="${dashboard_base}/nb-silent-auth" \
		NB_ENC="$encryption_key" \
		NB_RELAY="$relay_secret" \
		yq -i '
			.server.exposedAddress = strenv(NB_EXPOSED) |
			.server.authSecret = strenv(NB_RELAY) |
			.server.auth.issuer = strenv(NB_ISSUER) |
			.server.auth.dashboardRedirectURIs = [strenv(NB_NB_AUTH), strenv(NB_NB_SILENT)] |
			.server.store.encryptionKey = strenv(NB_ENC)' \
		"$config_file"

	if [[ -f "$dashboard_file" ]]; then
		_netbird_env_set_value "$dashboard_file" NETBIRD_MGMT_API_ENDPOINT "$mgmt_endpoint"
		_netbird_env_set_value "$dashboard_file" NETBIRD_MGMT_GRPC_API_ENDPOINT "$mgmt_endpoint"
		_netbird_env_set_value "$dashboard_file" AUTH_AUTHORITY "$issuer"
	fi
}

# Creates ~/.config/sandcat/netbird-server from template when missing.
# Idempotent: if destination exists, logs and skips.
provision_netbird_server_template() {
	local destination_dir template_dir
	destination_dir="$(sct_home)/netbird-server"
	template_dir="$SCT_TEMPLATEDIR/netbird-server"
	local required_file
	local -a required_files=(
		docker-compose.yml
		config.yaml
		dashboard.env
		netbird-server.env
		README.md
	)

	if [[ -e "$destination_dir" ]]; then
		echo "NetBird server template already exists at $destination_dir; skipping." | info
		return 0
	fi

	if [[ ! -d "$template_dir" ]]; then
		echo "Missing NetBird server template directory: $template_dir" | error
		return 1
	fi

	for required_file in "${required_files[@]}"; do
		if [[ ! -f "$template_dir/$required_file" ]]; then
			echo "Incomplete NetBird server template: missing $required_file in $template_dir" | error
			return 1
		fi
	done

	mkdir -p "$destination_dir"
	# Use rsync-style copy to include dotfiles (glob * skips them)
	cp -R "$template_dir/." "$destination_dir/"
	_netbird_apply_local_server_config "$destination_dir"
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
	export_netbird_management_url

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

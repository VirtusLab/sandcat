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
	echo "Restart netbird-server: sandcat netbird server start --force-recreate netbird-server" | info
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

# Resolve API token: NB_API_TOKEN env wins over settings. Prints token on success.
# Does not export settings-sourced tokens (avoids leaking via child process environ).
_netbird_api_token() {
	if [[ -n "${NB_API_TOKEN:-}" ]]; then
		printf '%s' "$NB_API_TOKEN"
		return 0
	fi

	local token
	token=$(netbird_read_setting netbird_api_token)
	if [[ -n "$token" ]]; then
		printf '%s' "$token"
		return 0
	fi

	echo "netbird_api_token is not set." >&2
	echo "Add it to $(sct_home)/settings.json (or export NB_API_TOKEN)." >&2
	echo "Create a token in the NetBird dashboard under API Keys, then run: sandcat edit user-settings" >&2
	echo "See cli/README.md § Dynamic networking (NetBird) for the full setup." >&2
	return 1
}

# Normalize the management server base URL (no trailing slash or /api suffix).
# Paths passed to netbird_api already include /api/...
netbird_management_base_url() {
	export_netbird_management_url
	local base="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
	base="${base%/}"
	if [[ "$base" == */api ]]; then
		base="${base%/api}"
	fi
	printf '%s' "$base"
}

# Returns 0 when the API response body indicates an invalid or missing token.
# NetBird self-hosted returns HTTP 404 with {"message":"invalid token: ..."}.
_netbird_api_body_indicates_auth_failure() {
	local body=$1
	[[ -n "$body" ]] || return 1
	[[ "$body" =~ [Ii]nvalid[[:space:]_]+token ]] && return 0
	[[ "$body" =~ [Tt]oken.*not[[:space:]]+found ]] && return 0
	[[ "$body" =~ [Nn]ot[[:space:]]+authenticated ]] && return 0
	[[ "$body" =~ [Uu]nauthorized ]] && return 0
	return 1
}

_netbird_api_print_auth_hint() {
	echo "  Authentication failed — check netbird_api_token in $(sct_home)/settings.json" >&2
	echo "  (or export NB_API_TOKEN). Create a Personal Access Token in the NetBird dashboard." >&2
}

# Prints actionable hints for failed NetBird API calls.
# Args:
#   $1 - HTTP status code (000 for connection failure)
#   $2 - HTTP method
#   $3 - API path
#   $4 - Full request URL
#   $5 - Optional response body
_netbird_api_print_error() {
	local http_code=$1
	local method=$2
	local path=$3
	local url=$4
	local body=${5:-}

	echo "NetBird API ${method} ${path} failed (HTTP ${http_code})." >&2
	echo "  URL: ${url}" >&2

	if _netbird_api_body_indicates_auth_failure "$body"; then
		_netbird_api_print_auth_hint
		[[ -n "$body" ]] && echo "  Response: ${body}" >&2
		return 0
	fi

	case "$http_code" in
	000)
		echo "  Could not reach the management server." >&2
		if [[ "$(netbird_management_base_url)" =~ localhost|127\.0\.0\.1 ]]; then
			echo "  Start it with: sandcat netbird server start" >&2
		fi
		;;
	401|403)
		_netbird_api_print_auth_hint
		;;
	404)
		echo "  Endpoint not found — check netbird_management_url in $(sct_home)/settings.json." >&2
		echo "  Use the management API base URL, not the dashboard:" >&2
		echo "    local template: http://localhost:33073  (not :8080)" >&2
		echo "    cloud:          (leave empty, defaults to https://api.netbird.io)" >&2
		echo "    self-hosted:    https://<your-domain>  (reverse proxy must forward /api to management)" >&2
		[[ -n "$body" ]] && echo "  Response: ${body}" >&2
		;;
	*)
		if [[ -n "$body" ]]; then
			echo "  Response: ${body}" >&2
		fi
		;;
	esac
}

# Calls the NetBird management REST API.
# Requires netbird_api_token in settings, or NB_API_TOKEN in the environment.
# NB_MANAGEMENT_URL defaults to https://api.netbird.io.
# Prints the response body on success; writes curl/API errors to stderr.
# Args:
#   $1 - HTTP method (GET, POST, PATCH, DELETE)
#   $2 - API path (e.g. /api/peers)
#   $3 - Optional JSON body
netbird_api() {
	local method=$1
	local path=$2
	local body=${3:-}
	local api_token

	api_token=$(_netbird_api_token) || return 1

	local base_url url
	base_url=$(netbird_management_base_url)
	url="${base_url}${path}"

	local -a args=(-sS -X "$method"
		-H "Authorization: Token $api_token"
		-H "Accept: application/json"
		-H "Content-Type: application/json")
	[[ -n "$body" ]] && args+=(-d "$body")
	args+=(-w $'\n%{http_code}')

	local raw http_code response
	local stderr_file
	stderr_file=$(mktemp)

	if ! raw=$(curl "${args[@]}" "$url" 2>"$stderr_file"); then
		_netbird_api_print_error "000" "$method" "$path" "$url" "$(<"$stderr_file")"
		rm -f "$stderr_file"
		return 1
	fi
	rm -f "$stderr_file"

	http_code=$(printf '%s' "$raw" | tail -n1)
	response=$(printf '%s' "$raw" | sed '$d')

	if [[ "$http_code" =~ ^2 ]]; then
		printf '%s\n' "$response"
		return 0
	fi

	_netbird_api_print_error "$http_code" "$method" "$path" "$url" "$response"
	return 1
}

# Returns the current peer list from the NetBird management server.
netbird_status() {
	netbird_api "GET" "/api/peers"
}

# Derives a NetBird network_id (1-40 chars) from a CIDR when none is supplied.
netbird_default_network_id() {
	local network=$1
	local id
	id=${network//./-}
	id=${id//\//-}
	printf '%.40s' "$id"
}

# URL-encode a path segment for safe use in API paths.
# Args:
#   $1 - Raw path segment
netbird_urlencode_path_segment() {
	local raw=$1
	local encoded=""
	local i ch hex
	for ((i = 0; i < ${#raw}; i++)); do
		ch=${raw:i:1}
		case "$ch" in
		[a-zA-Z0-9.~_-]) encoded+="$ch" ;;
		*)
			printf -v hex '%02X' "'$ch"
			encoded+="%${hex}"
			;;
		esac
	done
	printf '%s' "$encoded"
}

# Resolves NetBird route distribution group IDs (non-empty).
# Order: NB_ROUTE_GROUPS, netbird_route_groups setting, GET /api/groups (All).
# Prints one group ID per line.
netbird_route_distribution_group_ids() {
	local raw id

	if [[ -n "${NB_ROUTE_GROUPS:-}" ]]; then
		local IFS=,
		for id in $NB_ROUTE_GROUPS; do
			id=${id//[[:space:]]/}
			[[ -n "$id" ]] && printf '%s\n' "$id"
		done
		return 0
	fi

	raw=$(netbird_read_setting netbird_route_groups)
	if [[ -n "$raw" ]]; then
		if [[ "$raw" == \[* ]]; then
			require jq
			jq -r '.[]' <<<"$raw"
			return 0
		fi
		local IFS=,
		for id in $raw; do
			id=${id//[[:space:]]/}
			[[ -n "$id" ]] && printf '%s\n' "$id"
		done
		return 0
	fi

	require jq
	local groups
	groups=$(netbird_api "GET" "/api/groups?name=All") || return 1
	id=$(jq -r '.[] | select(.name == "All") | .id' <<<"$groups" | head -n1)
	if [[ -z "$id" ]]; then
		groups=$(netbird_api "GET" "/api/groups") || return 1
		id=$(jq -r '.[0].id // empty' <<<"$groups")
	fi
	if [[ -z "$id" ]]; then
		echo "No NetBird distribution groups found; set netbird_route_groups in settings or NB_ROUTE_GROUPS" >&2
		return 1
	fi
	printf '%s\n' "$id"
}

# Builds the JSON body for POST /api/routes (all NetBird-required fields).
# Args:
#   $1 - Network CIDR
#   $2 - Peer ID
#   $3 - network_id
#   $4 - metric (optional, default 9999)
netbird_route_create_body() {
	local network=$1 peer_id=$2 network_id=$3 metric=${4:-9999}
	require jq

	local -a group_ids=()
	local gid
	while IFS= read -r gid; do
		[[ -n "$gid" ]] && group_ids+=("$gid")
	done < <(netbird_route_distribution_group_ids) || return 1
	if [[ ${#group_ids[@]} -eq 0 ]]; then
		echo "NetBird route distribution groups list is empty" >&2
		return 1
	fi

	local groups_json
	groups_json=$(printf '%s\n' "${group_ids[@]}" | jq -R . | jq -s .)

	jq -nc \
		--arg description "sandcat route ${network_id}" \
		--arg network_id "$network_id" \
		--arg network "$network" \
		--arg peer "$peer_id" \
		--argjson metric "$metric" \
		--argjson groups "$groups_json" \
		'{description: $description, network_id: $network_id, enabled: true, peer: $peer, network: $network, metric: $metric, masquerade: true, groups: $groups, keep_route: false}'
}

# Adds a network route served by a peer.
# Args:
#   $1 - Network CIDR (e.g. 10.8.0.0/24)
#   $2 - Peer ID that serves the route
#   $3 - Optional network_id (defaults to a slug derived from the CIDR)
#   $4 - Optional route metric 1-9999 (default 9999; lower = higher priority)
netbird_route_add() {
	local network=$1
	local peer_id=$2
	local network_id=${3:-$(netbird_default_network_id "$network")}
	local metric=${4:-9999}
	local body

	body=$(netbird_route_create_body "$network" "$peer_id" "$network_id" "$metric") || return 1
	netbird_api "POST" "/api/routes" "$body"
}

# Enables an existing network route by ID (GET + PUT; NetBird has no PATCH).
# Args:
#   $1 - Route ID
netbird_route_enable() {
	local route_id=$1
	local route_id_escaped
	route_id_escaped=$(netbird_urlencode_path_segment "$route_id")
	require jq
	local route body
	route=$(netbird_api "GET" "/api/routes/$route_id_escaped") || return 1
	body=$(jq '.enabled = true | del(.id, .network_type)' <<<"$route")
	netbird_api "PUT" "/api/routes/$route_id_escaped" "$body"
}

# Disables an existing network route by ID without deleting it.
# Args:
#   $1 - Route ID
netbird_route_disable() {
	local route_id=$1
	local route_id_escaped
	route_id_escaped=$(netbird_urlencode_path_segment "$route_id")
	require jq
	local route body
	route=$(netbird_api "GET" "/api/routes/$route_id_escaped") || return 1
	body=$(jq '.enabled = false | del(.id, .network_type)' <<<"$route")
	netbird_api "PUT" "/api/routes/$route_id_escaped" "$body"
}

# Removes a network route by ID.
# Args:
#   $1 - Route ID (returned by netbird_route_add)
netbird_route_remove() {
	local route_id=$1
	local route_id_escaped
	route_id_escaped=$(netbird_urlencode_path_segment "$route_id")
	netbird_api "DELETE" "/api/routes/$route_id_escaped"
}

# Removes a peer from the NetBird management server.
# The netbird daemon running in wg-client detects the removal and drops the
# peer from wt0, which removes the route to that endpoint for the agent.
# Args:
#   $1 - Peer ID
netbird_peer_remove() {
	local peer_id=$1
	local peer_id_escaped
	peer_id_escaped=$(netbird_urlencode_path_segment "$peer_id")
	netbird_api "DELETE" "/api/peers/$peer_id_escaped"
}

# Returns the provisioned self-hosted NetBird server directory.
netbird_server_dir() {
	printf '%s\n' "$(sct_home)/netbird-server"
}

# Verifies the local netbird-server template was provisioned.
_ensure_netbird_server_provisioned() {
	local server_dir compose_file env_file
	server_dir=$(netbird_server_dir)
	compose_file="$server_dir/docker-compose.yml"
	env_file="$server_dir/netbird-server.env"

	if [[ ! -f "$compose_file" || ! -f "$env_file" ]]; then
		echo "NetBird server not provisioned at $server_dir" | error
		echo "Run: sandcat init --netbird --netbird-server new" >&2
		return 1
	fi
}

# Runs docker compose in the provisioned netbird-server directory.
# Args: docker compose subcommand and options (e.g. up -d, down, ps)
netbird_server_compose() {
	require docker
	_ensure_netbird_server_provisioned || return 1

	local server_dir compose_file env_file
	server_dir=$(netbird_server_dir)
	compose_file="$server_dir/docker-compose.yml"
	env_file="$server_dir/netbird-server.env"

	docker compose -f "$compose_file" --env-file "$env_file" "$@"
}

# Starts the provisioned self-hosted NetBird server stack.
# Remaining args are passed to docker compose (e.g. --force-recreate netbird-server).
netbird_server_start() {
	netbird_sync_local_server_exposed_address
	netbird_server_compose up -d "$@"
}

# Stops the provisioned self-hosted NetBird server stack.
# Remaining args are passed to docker compose (e.g. -v to remove volumes).
netbird_server_stop() {
	netbird_server_compose down "$@"
}

# Shows container status for the provisioned self-hosted NetBird server stack.
netbird_server_status() {
	netbird_server_compose ps
}

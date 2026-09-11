#!/bin/bash

netbird_peer_log() {
	local prefix="${NETBIRD_PEER_LOG_PREFIX:-netbird}"
	echo "[${prefix}] $*" >&2
}

NETBIRD_PASS_CLI_LOGGED_IN=0
NETBIRD_PASS_CLI_WARMED=0

netbird_pass_cli_login_once() {
	if [[ "${NETBIRD_PASS_CLI_LOGGED_IN}" -eq 1 ]]; then
		return 0
	fi
	pass-cli login || {
		netbird_peer_log "pass-cli login failed"
		return 1
	}
	# Reject full-account credentials the same way the mitmproxy addon does:
	# pass-cli info prints "Personal Access Token:" only for PAT sessions.
	local info_out
	info_out=$(pass-cli info 2>/dev/null) || {
		netbird_peer_log "pass-cli info failed; cannot verify PAT session — logging out"
		pass-cli logout >/dev/null 2>&1 || true
		return 1
	}
	if ! printf '%s' "$info_out" | grep -qiE '^\s*-?\s*personal\s+access\s+token\s*:'; then
		netbird_peer_log "pass-cli session is not a Personal Access Token — logging out"
		pass-cli logout >/dev/null 2>&1 || true
		return 1
	fi
	NETBIRD_PASS_CLI_LOGGED_IN=1
}

netbird_pass_cli_warmup_once() {
	if [[ "${NETBIRD_PASS_CLI_WARMED}" -eq 1 ]]; then
		return 0
	fi
	# First item view after login can stall on a cold vault sync. Warm the
	# cache once; failure is non-fatal because item view retries below.
	timeout 60 pass-cli vault list >/dev/null 2>&1 || {
		netbird_peer_log "pass-cli vault list warmup failed"
	}
	NETBIRD_PASS_CLI_WARMED=1
}

netbird_resolve_secret_ref() {
	local value=${1-}
	local output
	if [[ "$value" == op://* ]]; then
		output=$(timeout 60 op read "$value") || {
			netbird_peer_log "op read failed for ${value}"
			return 1
		}
		printf '%s\n' "$output"
		return 0
	fi
	if [[ "$value" == pass://* ]]; then
		netbird_pass_cli_login_once || return 1
		netbird_pass_cli_warmup_once
		if output=$(timeout 60 pass-cli item view "$value"); then
			printf '%s\n' "$output"
			return 0
		fi
		output=$(timeout 60 pass-cli item view "$value") || {
			netbird_peer_log "pass-cli item view failed for ${value}"
			return 1
		}
		printf '%s\n' "$output"
		return 0
	fi
	printf '%s' "$value"
}

netbird_json_field() {
	local file=$1 key=$2
	[[ -f "$file" ]] || { printf 'null'; return 0; }
	command -v jq >/dev/null 2>&1 || { printf 'null'; return 0; }
	jq -c --arg k "$key" '.[$k] // null' "$file"
}

netbird_flatten_secret_json() {
	local json=$1
	[[ "$json" == "null" || -z "$json" ]] && { printf ''; return 0; }
	command -v jq >/dev/null 2>&1 || { printf '%s' "$json"; return 0; }
	local typ
	typ=$(printf '%s' "$json" | jq -r 'type')
	case "$typ" in
	string)
		printf '%s' "$(printf '%s' "$json" | jq -r '.')"
		;;
	object)
		local n
		n=$(printf '%s' "$json" | jq '[.value, .op, .pass] | map(select(. != null)) | length')
		if [[ "$n" != "1" ]]; then
			netbird_peer_log "settings secret must specify exactly one of value, op, or pass"
			return 1
		fi
		printf '%s' "$(printf '%s' "$json" | jq -r '.value // .op // .pass')"
		;;
	*)
		netbird_peer_log "settings secret must be a string or object"
		return 1
		;;
	esac
}

netbird_prepare_enroll_credentials() {
	local settings_path="${NETBIRD_SETTINGS_PATH:-/config/settings.json}"
	local raw flat
	if [[ -z "${NB_SETUP_KEY:-}" ]]; then
		raw=$(netbird_json_field "$settings_path" netbird_enrollment_key)
		flat=$(netbird_flatten_secret_json "$raw") || return 1
		[[ -n "$flat" ]] && export NB_SETUP_KEY="$flat"
	fi
	if [[ -z "${NB_API_TOKEN:-}" ]]; then
		raw=$(netbird_json_field "$settings_path" netbird_api_token)
		flat=$(netbird_flatten_secret_json "$raw") || return 1
		[[ -n "$flat" ]] && export NB_API_TOKEN="$flat"
	fi
	if [[ -n "${NB_SETUP_KEY:-}" ]]; then
		NB_SETUP_KEY=$(netbird_resolve_secret_ref "$NB_SETUP_KEY") || return 1
		export NB_SETUP_KEY
	fi
	if [[ -n "${NB_API_TOKEN:-}" ]]; then
		NB_API_TOKEN=$(netbird_resolve_secret_ref "$NB_API_TOKEN") || return 1
		export NB_API_TOKEN
	fi
}

netbird_daemon_status() {
	local json status
	json=$(netbird status --json 2>/dev/null) || return 1
	status=$(printf '%s' "$json" | jq -r '.status // .daemonStatus // .daemon.status // empty' 2>/dev/null) || return 1
	[[ -n "$status" ]] || return 1
	printf '%s' "$status"
}

# 0.72 Start() creates /var/lib/netbird/default.json and stays NeedsLogin until
# `netbird up --setup-key`. That file is not enrolled identity.
netbird_profile_is_enrolled() {
	local status
	status=$(netbird_daemon_status) || return 1
	[[ "$status" != "NeedsLogin" && "$status" != "LoginFailed" && "$status" != "NeedsLoginSSO" ]]
}

netbird_local_state_present() {
	local state_root="${NETBIRD_STATE_ROOT:-/var/lib/netbird}"

	[[ -s "${state_root}/config.json" ]] && return 0
	[[ -s /etc/netbird/config.json ]] && return 0
	if [[ -s "${state_root}/default.json" ]] && netbird_profile_is_enrolled; then
		return 0
	fi
	return 1
}

# Go encoding/json for net/url.URL (NetBird 0.72 Config.ManagementURL).
netbird_go_url_json() {
	local url=$1
	[[ "$url" =~ ^(https?)://([^/?#]+)([^?#]*) ]] || return 1
	jq -nc --arg Scheme "${BASH_REMATCH[1]}" --arg Host "${BASH_REMATCH[2]}" --arg Path "${BASH_REMATCH[3]}" \
		'{Scheme:$Scheme, Host:$Host, Path:$Path}'
}

# NetBird 0.72 unmarshals ManagementURL/AdminURL as *url.URL. A JSON string
# (0.28 seed format) fatal's the daemon. Never create default.json; only
# coerce leftover string URLs and refresh ManagementURL from NB_MANAGEMENT_URL
# so a cloud enroll cannot inherit a stale self-hosted host from the volume.
netbird_prepare_local_management_profile() {
	local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
	local state_root="${NETBIRD_STATE_ROOT:-/var/lib/netbird}"
	local profile_file="${state_root}/default.json"
	local url_json tmp

	command -v jq >/dev/null 2>&1 || return 0
	[[ -f "$profile_file" ]] || return 0

	tmp=$(mktemp)
	local jq_rc=0
	if url_json=$(netbird_go_url_json "$mgmt_url"); then
		if [[ -n "${NETBIRD_WG_PORT:-}" ]]; then
			jq --argjson mgmt "$url_json" --arg iface "${NETBIRD_IFACE:-wt0}" --argjson port "${NETBIRD_WG_PORT}" \
				'.ManagementURL = $mgmt | .AdminURL = $mgmt | .WgIface = $iface | .WgPort = $port' \
				"$profile_file" >"$tmp" || jq_rc=$?
		else
			jq --argjson mgmt "$url_json" --arg iface "${NETBIRD_IFACE:-wt0}" \
				'.ManagementURL = $mgmt | .AdminURL = $mgmt | .WgIface = $iface' \
				"$profile_file" >"$tmp" || jq_rc=$?
		fi
	else
		jq '
			def coerce:
			  if type == "string" then
			    (capture("^(?<Scheme>https?)://(?<Host>[^/?#]+)(?<Path>[^?#]*)") // .)
			  else . end;
			.ManagementURL |= coerce
			| .AdminURL |= coerce
		' "$profile_file" >"$tmp" || jq_rc=$?
	fi
	if [[ "$jq_rc" -ne 0 ]]; then
		rm -f "$tmp"
		return "$jq_rc"
	fi
	mv "$tmp" "$profile_file"
}

netbird_resolve_api_token() {
	local settings_path="${NETBIRD_SETTINGS_PATH:-/config/settings.json}"
	local token raw flat

	if [[ -n "${NB_API_TOKEN:-}" ]]; then
		token="$NB_API_TOKEN"
	else
		raw=$(netbird_json_field "$settings_path" netbird_api_token)
		flat=$(netbird_flatten_secret_json "$raw") || return 1
		token="$flat"
	fi

	[[ -n "$token" ]] || return 1
	token=$(netbird_resolve_secret_ref "$token") || return 1
	[[ -n "$token" ]] || return 1
	printf '%s\n' "$token"
}

netbird_mgmt_find_peer_id_by_name() {
	local peer_name=$1
	local management_url="${NB_MANAGEMENT_URL:?NB_MANAGEMENT_URL is required}"
	local token peers matches match_count
	token=$(netbird_resolve_api_token) || {
		netbird_peer_log "netbird_api_token / NB_API_TOKEN required to query management peers"
		return 1
	}

	peers=$(netbird_curl "$token" "${management_url%/}/api/peers") || return 1
	matches=$(printf '%s' "$peers" \
		| jq -c --arg name "$peer_name" \
			'[.[] | select(
				((.name // "") | ascii_downcase) == ($name | ascii_downcase)
				or ((.hostname // "") | ascii_downcase) == ($name | ascii_downcase)
				or ((.dns_label // "") | ascii_downcase) == ($name | ascii_downcase)
			) | .id]') || return 1
	match_count=$(printf '%s' "$matches" | jq 'length') || return 1
	if ((match_count > 1)); then
		netbird_peer_log "multiple management peers match '${peer_name}'; refusing ambiguous replacement"
		return 1
	fi

	printf '%s' "$matches" | jq -r '.[0] // empty'
}

# curl against the management API without putting the PAT on argv.
# $1 is the token; remaining args are extra curl arguments (URL last).
netbird_curl() {
	local token=$1
	shift
	local header_file rc
	local old_umask
	old_umask=$(umask)
	umask 077
	header_file=$(mktemp)
	umask "$old_umask"
	printf 'Authorization: Token %s\n' "$token" >"$header_file"
	curl -sf --max-time 10 -H "@${header_file}" "$@"
	rc=$?
	rm -f "$header_file"
	return "$rc"
}

netbird_mgmt_delete_peer_by_id() {
	local peer_id=$1
	local token

	token=$(netbird_resolve_api_token) || {
		netbird_peer_log "netbird_api_token / NB_API_TOKEN required to delete management peer '${peer_id}'"
		return 1
	}

	netbird_curl "$token" -X DELETE \
		"${NB_MANAGEMENT_URL%/}/api/peers/${peer_id}" >/dev/null
}

netbird_mgmt_delete_peer_by_name() {
	local peer_name=$1
	local peer_id

	netbird_resolve_api_token >/dev/null || {
		netbird_peer_log "netbird_api_token / NB_API_TOKEN required to delete management peer '${peer_name}'"
		return 1
	}

	peer_id=$(netbird_mgmt_find_peer_id_by_name "$peer_name") || return 1
	[[ -n "$peer_id" ]] || return 0

	netbird_mgmt_delete_peer_by_id "$peer_id"
}

netbird_replace_same_name_peer_if_needed() {
	local peer_name="${NB_PEER_NAME:?NB_PEER_NAME is required}"
	local peer_id

	if netbird_local_state_present; then
		netbird_peer_log "local state present — will reconnect as '${peer_name}'"
		return 0
	fi

	# Without a PAT we cannot query management; skip replace and let netbird up
	# enroll fresh. FQDN may get an IP suffix but enrollment is not blocked.
	if ! netbird_resolve_api_token >/dev/null 2>&1; then
		netbird_peer_log "no API token — skipping same-name peer check; will enroll fresh"
		return 0
	fi

	peer_id=$(netbird_mgmt_find_peer_id_by_name "$peer_name") || return 1
	if [[ -z "$peer_id" ]]; then
		netbird_peer_log "no existing management peer named '${peer_name}' — will enroll fresh"
		return 0
	fi

	netbird_peer_log "replace existing management peer '${peer_name}' (id=${peer_id}) before enroll"
	netbird_mgmt_delete_peer_by_id "$peer_id"
}

netbird_set_dns_label() {
	local peer_name="${NB_PEER_NAME:?NB_PEER_NAME is required}"
	local management_url="${NB_MANAGEMENT_URL:-}"
	local token current_fqdn peer_id result new_fqdn payload

	[[ -n "$management_url" ]] || return 0
	command -v curl >/dev/null 2>&1 || return 0
	command -v jq >/dev/null 2>&1 || return 0

	token=$(netbird_resolve_api_token) || {
		netbird_peer_log "netbird_api_token not set; skipping dns_label update (FQDN will include IP suffix)."
		return 0
	}
	current_fqdn=$(netbird status --json 2>/dev/null \
		| jq -r '.fqdn // empty' 2>/dev/null || true)
	if [[ -z "$current_fqdn" ]]; then
		netbird_peer_log "could not read local peer FQDN; skipping dns_label update."
		return 0
	fi

	peer_id=$(netbird_curl "$token" "${management_url%/}/api/peers" \
		| jq -r --arg fqdn "$current_fqdn" \
			'first(.[] | select(.fqdn == $fqdn) | .id) // empty' 2>/dev/null || true)
	if [[ -z "$peer_id" ]]; then
		netbird_peer_log "could not find peer ID for FQDN ${current_fqdn}; skipping dns_label update."
		return 0
	fi

	payload=$(jq -cn --arg dns_label "$peer_name" '{dns_label: $dns_label}')
	result=$(netbird_curl "$token" -X PUT \
		-H "Content-Type: application/json" \
		-d "$payload" \
		"${management_url%/}/api/peers/${peer_id}" 2>/dev/null) || {
		netbird_peer_log "dns_label update failed for peer ${peer_id}; FQDN may retain IP suffix."
		return 0
	}

	new_fqdn=$(printf '%s' "$result" | jq -r '.fqdn // empty' 2>/dev/null || true)
	netbird_peer_log "dns_label set → FQDN: ${new_fqdn:-${peer_name}.<domain>}"
}

wait_until() {
	local max="$1" delay="$2" msg="$3"
	shift 3
	local attempt=0
	while ! "$@"; do
		if [[ "$attempt" -ge "$max" ]]; then
			echo "$msg" >&2
			return 1
		fi
		sleep "$delay"
		attempt=$((attempt + 1))
	done
}

netbird_management_url_host() {
	local url=$1
	[[ "$url" =~ ^https?://([^/:]+) ]] || return 1
	printf '%s' "${BASH_REMATCH[1]}"
}

netbird_management_url_host_is_literal_ipv4() {
	local host=$1
	[[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

netbird_management_url_port() {
	local url=$1
	if [[ "$url" =~ :([0-9]+)(/|$|\?) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$url" =~ ^https:// ]]; then
		printf '443'
	else
		printf '80'
	fi
}

netbird_host_route_uses_gateway() {
	local host_ip=$1
	local docker_gateway=$2
	[[ -n "$host_ip" && -n "$docker_gateway" ]] || return 1
	[[ "$host_ip" != "$docker_gateway" ]]
}

# Allow enrollment against a self-hosted management server on the Docker host.
configure_netbird_host_management_access() {
	local docker_gateway=$1
	local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
	local host_ip port

	[[ -n "$docker_gateway" ]] || return 0

	host_ip=$(netbird_management_url_host "$mgmt_url") || return 0
	netbird_management_url_host_is_literal_ipv4 "$host_ip" || return 0

	port=$(netbird_management_url_port "$mgmt_url")

	if netbird_host_route_uses_gateway "$host_ip" "$docker_gateway"; then
		netbird_peer_log "Routing NetBird management traffic to ${host_ip}:${port} via eth0 (via ${docker_gateway})."
		ip -4 route add "${host_ip}/32" via "${docker_gateway}" dev eth0 2>/dev/null || true
	else
		netbird_peer_log "Routing NetBird management traffic to ${host_ip}:${port} via eth0."
		ip -4 route add "${host_ip}/32" dev eth0 2>/dev/null || true
	fi

	ip -4 rule add to "${host_ip}/32" lookup main priority 50 2>/dev/null || true

	iptables -C OUTPUT -o eth0 -d "$host_ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
		|| iptables -I OUTPUT 1 -o eth0 -d "$host_ip" -p tcp --dport "$port" -j ACCEPT
	iptables -C OUTPUT -o eth0 -d "$host_ip" -p udp --dport 3478 -j ACCEPT 2>/dev/null \
		|| iptables -I OUTPUT 1 -o eth0 -d "$host_ip" -p udp --dport 3478 -j ACCEPT
}

netbird_verify_host_management_reachable() {
	local mgmt_url="${NB_MANAGEMENT_URL:-}"
	local host_ip port check_url

	host_ip=$(netbird_management_url_host "$mgmt_url") || return 0
	netbird_management_url_host_is_literal_ipv4 "$host_ip" || return 0

	port=$(netbird_management_url_port "$mgmt_url")
	command -v curl >/dev/null 2>&1 || return 0

	check_url="${mgmt_url%/}/api/instance"
	wait_until 15 1 \
		"[${NETBIRD_PEER_LOG_PREFIX:-netbird}] Cannot reach NetBird management at ${mgmt_url}; is the server running on the host (port ${port})?" \
		curl -sf --max-time 5 "$check_url" >/dev/null
}

netbird_export_service_env() {
	local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
	export NB_MANAGEMENT_URL="$mgmt_url"
	if [[ -n "${NETBIRD_WG_PORT:-}" ]]; then
		export NB_WIREGUARD_PORT="${NETBIRD_WG_PORT}"
	fi
	if netbird_management_url_host_is_literal_ipv4 "$(netbird_management_url_host "$mgmt_url" 2>/dev/null)"; then
		export NB_USE_LEGACY_ROUTING=true
	fi
}

netbird_daemon_ready() {
	netbird status >/dev/null 2>&1
}

ensure_netbird_service() {
	netbird_prepare_local_management_profile
	netbird_export_service_env
	if netbird_daemon_ready; then
		return 0
	fi

	netbird_peer_log "Starting NetBird service daemon ($(netbird version 2>/dev/null || echo unknown))."
	netbird service run --log-file console &

	wait_until 30 1 \
		"[${NETBIRD_PEER_LOG_PREFIX:-netbird}] Timed out waiting for NetBird service daemon" \
		netbird_daemon_ready
}

# Enroll without putting the setup key on argv. Bound by NETBIRD_UP_TIMEOUT.
netbird_up_enroll() {
	local iface=$1
	local keyfile rc
	local old_umask
	local -a up_args
	old_umask=$(umask)
	umask 077
	keyfile=$(mktemp)
	umask "$old_umask"
	printf '%s' "${NB_SETUP_KEY}" >"$keyfile"

	up_args=(
		up
		--setup-key-file "$keyfile"
		--management-url "${NB_MANAGEMENT_URL:-https://api.netbird.io}"
		--hostname "${NB_PEER_NAME}"
		--interface-name "${iface}"
	)
	if [[ -n "${NETBIRD_WG_PORT:-}" ]]; then
		up_args+=(--wireguard-port "${NETBIRD_WG_PORT}")
	fi

	netbird_peer_log "Enrolling NetBird peer on ${iface} as '${NB_PEER_NAME}'${NETBIRD_WG_PORT:+ (WG port ${NETBIRD_WG_PORT})}."
	timeout "${NETBIRD_UP_TIMEOUT:-60}" netbird "${up_args[@]}"
	rc=$?
	rm -f "$keyfile"
	if [[ "$rc" -ne 0 ]]; then
		netbird_peer_log "netbird up failed for ${iface}."
		return "$rc"
	fi
	return 0
}

netbird_start() {
	local iface="${1:-wt0}"
	local docker_gateway

	docker_gateway=$(ip -4 route show default dev eth0 2>/dev/null | awk '{print $3}')

	ensure_netbird_service
	configure_netbird_host_management_access "$docker_gateway"
	netbird_verify_host_management_reachable
	netbird_prepare_local_management_profile
	if [[ -f /var/lib/netbird/default.json ]] \
		&& grep -qE 'localhost|127\.0\.0\.1|\[::1\]' /var/lib/netbird/default.json 2>/dev/null; then
		netbird down 2>/dev/null || true
	fi
	netbird_export_service_env

	netbird_prepare_enroll_credentials || return 1
	netbird_replace_same_name_peer_if_needed || return 1
	netbird_up_enroll "$iface" || return 1

	if ! wait_until 30 1 \
		"[${NETBIRD_PEER_LOG_PREFIX:-netbird}] Timed out waiting for NetBird to bring up ${iface}" \
		ip link show "${iface}" >/dev/null 2>&1; then
		return 1
	fi
	if [[ -n "${NETBIRD_AFTER_UP:-}" ]]; then
		"${NETBIRD_AFTER_UP}" "$iface"
	fi
}

start_netbird() {
	netbird_start "$@"
}

netbird_shutdown() {
	netbird down >/dev/null 2>&1 || true
}

netbird_supervise_daemon() {
	local iface="${1:-wt0}"
	local backoff="${NETBIRD_SUPERVISE_INTERVAL:-10}"
	local max_backoff="${NETBIRD_SUPERVISE_MAX_BACKOFF:-60}"

	while true; do
		sleep "$backoff"
		if ! netbird_daemon_ready; then
			netbird_peer_log "NetBird service daemon not responding; restarting."
			netbird_export_service_env
			netbird service run --log-file console &
			wait_until 15 1 \
				"[${NETBIRD_PEER_LOG_PREFIX:-netbird}] Timed out waiting for NetBird service daemon" \
				netbird_daemon_ready || true
		fi
		if ! ip link show "${iface}" >/dev/null 2>&1; then
			netbird_peer_log "NetBird interface ${iface} down; re-enrolling."
			if netbird_start "$iface"; then
				backoff="${NETBIRD_SUPERVISE_INTERVAL:-10}"
			else
				backoff=$((backoff * 2))
				if ((backoff > max_backoff)); then
					backoff=$max_backoff
				fi
			fi
		fi
	done
}

supervise_netbird_daemon() {
	netbird_supervise_daemon "$@"
}

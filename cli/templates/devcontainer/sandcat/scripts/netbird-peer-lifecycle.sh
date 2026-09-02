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
	if [[ "$value" == op://* ]]; then
		timeout 60 op read "$value" || {
			netbird_peer_log "op read failed for ${value}"
			return 1
		}
		return 0
	fi
	if [[ "$value" == pass://* ]]; then
		netbird_pass_cli_login_once || return 1
		netbird_pass_cli_warmup_once
		timeout 60 pass-cli item view "$value" && return 0
		timeout 60 pass-cli item view "$value" || {
			netbird_peer_log "pass-cli item view failed for ${value}"
			return 1
		}
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
# coerce leftover string URLs and refresh IPv4 self-hosted fields in place.
netbird_prepare_local_management_profile() {
	local mgmt_url="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
	local state_root="${NETBIRD_STATE_ROOT:-/var/lib/netbird}"
	local profile_file="${state_root}/default.json"
	local host update_urls=false url_json tmp

	command -v jq >/dev/null 2>&1 || return 0
	[[ -f "$profile_file" ]] || return 0

	if [[ "$mgmt_url" =~ ^https?://([^/:]+) ]]; then
		host="${BASH_REMATCH[1]}"
		if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
			update_urls=true
		fi
	fi

	tmp=$(mktemp)
	if [[ "$update_urls" == true ]] && url_json=$(netbird_go_url_json "$mgmt_url"); then
		if [[ -n "${NETBIRD_WG_PORT:-}" ]]; then
			jq --argjson mgmt "$url_json" --arg iface "${NETBIRD_IFACE:-wt0}" --argjson port "${NETBIRD_WG_PORT}" \
				'.ManagementURL = $mgmt | .AdminURL = $mgmt | .WgIface = $iface | .WgPort = $port' \
				"$profile_file" >"$tmp"
		else
			jq --argjson mgmt "$url_json" --arg iface "${NETBIRD_IFACE:-wt0}" \
				'.ManagementURL = $mgmt | .AdminURL = $mgmt | .WgIface = $iface' \
				"$profile_file" >"$tmp"
		fi
	else
		jq '
			def coerce:
			  if type == "string" then
			    (capture("^(?<Scheme>https?)://(?<Host>[^/?#]+)(?<Path>[^?#]*)") // .)
			  else . end;
			.ManagementURL |= coerce
			| .AdminURL |= coerce
		' "$profile_file" >"$tmp"
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

	peers=$(curl -sf --max-time 10 \
		-H "Authorization: Token ${token}" \
		"${management_url%/}/api/peers") || return 1
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

netbird_mgmt_delete_peer_by_id() {
	local peer_id=$1
	local token

	token=$(netbird_resolve_api_token) || {
		netbird_peer_log "netbird_api_token / NB_API_TOKEN required to delete management peer '${peer_id}'"
		return 1
	}

	curl -sf --max-time 10 -X DELETE \
		-H "Authorization: Token ${token}" \
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

	peer_id=$(curl -sf --max-time 10 \
		-H "Authorization: Token ${token}" \
		"${management_url%/}/api/peers" \
		| jq -r --arg fqdn "$current_fqdn" \
			'first(.[] | select(.fqdn == $fqdn) | .id) // empty' 2>/dev/null || true)
	if [[ -z "$peer_id" ]]; then
		netbird_peer_log "could not find peer ID for FQDN ${current_fqdn}; skipping dns_label update."
		return 0
	fi

	payload=$(jq -cn --arg dns_label "$peer_name" '{dns_label: $dns_label}')
	result=$(curl -sf --max-time 10 -X PUT \
		-H "Authorization: Token ${token}" \
		-H "Content-Type: application/json" \
		-d "$payload" \
		"${management_url%/}/api/peers/${peer_id}" 2>/dev/null) || {
		netbird_peer_log "dns_label update failed for peer ${peer_id}; FQDN may retain IP suffix."
		return 0
	}

	new_fqdn=$(printf '%s' "$result" | jq -r '.fqdn // empty' 2>/dev/null || true)
	netbird_peer_log "dns_label set → FQDN: ${new_fqdn:-${peer_name}.<domain>}"
}

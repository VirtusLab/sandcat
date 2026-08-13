#!/bin/bash

netbird_peer_log() {
	local prefix="${NETBIRD_PEER_LOG_PREFIX:-netbird}"
	echo "[${prefix}] $*" >&2
}

netbird_local_state_present() {
	local state_root="${NETBIRD_STATE_ROOT:-/var/lib/netbird}"

	[[ -s "${state_root}/config.json" ]] && return 0
	[[ -s /etc/netbird/config.json ]] && return 0
	return 1
}

netbird_resolve_api_token() {
	local settings_path="${NETBIRD_SETTINGS_PATH:-/config/settings.json}"

	if [[ -n "${NB_API_TOKEN:-}" ]]; then
		printf '%s\n' "$NB_API_TOKEN"
		return 0
	fi
	if [[ -f "$settings_path" ]]; then
		local token
		token=$(jq -r '.netbird_api_token // empty' "$settings_path" 2>/dev/null || true)
		if [[ -n "$token" ]]; then
			printf '%s\n' "$token"
			return 0
		fi
	fi
	return 1
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

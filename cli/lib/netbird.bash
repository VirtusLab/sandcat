#!/usr/bin/env bash

# Calls the NetBird management REST API.
# Requires NB_API_TOKEN. NB_MANAGEMENT_URL defaults to https://api.netbird.io.
# Args:
#   $1 - HTTP method (GET, POST, DELETE)
#   $2 - API path (e.g. /api/peers)
#   $3 - Optional JSON body
netbird_api() {
    local method=$1
    local path=$2
    local body=${3:-}

    if [[ -z "${NB_API_TOKEN:-}" ]]; then
        echo "NB_API_TOKEN is not set" >&2
        return 1
    fi

    local url="${NB_MANAGEMENT_URL:-https://api.netbird.io}${path}"
    local args=(-sf -X "$method"
        -H "Authorization: Token $NB_API_TOKEN"
        -H "Content-Type: application/json")

    [[ -n "$body" ]] && args+=(-d "$body")

    curl "${args[@]}" "$url"
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

# NetBird Dynamic WireGuard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a NetBird sidecar container to sandcat's proxy stack so that the WireGuard peer configuration on `wg0` becomes dynamically controllable at runtime — enabling routes and peer access to be added or removed without restarting any container.

**Architecture:** The system follows a strict manager/consumer split that mirrors the existing `mitmproxy → wg-client` pattern. A new `netbird` container is a low-privilege management API client: it polls the NetBird management server and writes a WireGuard `syncconf`-compatible peer config file (`peers.conf`) to a shared volume. It owns no network interfaces and requires no kernel capabilities. `wg-client` remains the sole owner of `NET_ADMIN`, `wg0`, and iptables; it gains a `supervise_netbird_config` watcher loop (alongside the existing `supervise_dnsmasq` loop) that detects changes to `peers.conf` and applies them via `wg syncconf wg0`. Physical capability revocation therefore flows: NetBird management server removes a peer → `netbird` container writes updated `peers.conf` → `wg-client` calls `wg syncconf` → agent loses routing to that endpoint.

**Tech Stack:** Bash (`bats`, `bats-mock-ext`, `yq`, `inotifywait` from `inotify-tools`), Docker Compose, Debian slim + curl + jq (custom `netbird` image), NetBird management REST API (v1).

---

## File Structure and Responsibilities

- Create: `cli/templates/devcontainer/sandcat/Dockerfile.netbird`
  - Minimal Debian image with `curl`, `jq`. No caps. Custom entrypoint only.
- Create: `cli/templates/devcontainer/sandcat/scripts/netbird-sync.sh`
  - Polls NetBird management API; writes WireGuard-format `peers.conf` to shared volume; loops.
- Create: `cli/templates/devcontainer/sandcat/compose-netbird.yml`
  - Defines the `netbird` service: no `cap_add`, mounts `netbird-config` volume writable, mounts `mitmproxy-config` read-only (for CA cert).
- Modify: `cli/templates/devcontainer/sandcat/compose-proxy.yml`
  - Extend `wg-client` service to mount `netbird-config` volume read-only.
- Modify: `cli/templates/devcontainer/sandcat/scripts/wg-client-init.sh`
  - Add `supervise_netbird_config` function: watches `/run/netbird/peers.conf` and calls `wg syncconf wg0` on change.
- Modify: `cli/templates/devcontainer/sandcat/Dockerfile.wg-client`
  - Install `inotify-tools` so `inotifywait` is available for the watcher.
- Modify: `cli/templates/devcontainer/compose-all.yml`
  - Add `include` for `compose-netbird.yml` (opt-in; included only when NetBird is enabled).
- Modify: `cli/lib/composefile.bash`
  - Add `enable_netbird` function.
- Modify: `cli/libexec/init/devcontainer`
  - Accept `--netbird` flag; call `enable_netbird` when present.
- Modify: `cli/libexec/init/init`
  - Add `--netbird` flag; seed `netbird_enrollment_key` in user settings; pass flag to `devcontainer`.
- Create: `cli/lib/netbird.bash`
  - Pure helper functions for the NetBird management REST API. Testable without Docker.
- Create: `cli/libexec/netbird/netbird`
  - Subcommand dispatcher: `up`, `down`, `route`, `status`.
- Create: `cli/test/composefile/netbird.bats`
  - Tests for `enable_netbird` function.
- Create: `cli/test/composefile/netbird_contract.bats`
  - Structural contracts: no caps on `netbird` service; `wg-client` mounts `netbird-config` read-only; default template excludes NetBird.
- Create: `cli/test/netbird/test_helper.bash`
  - Standard test setup.
- Create: `cli/test/netbird/netbird_api.bats`
  - Unit tests for `netbird.bash` helpers.
- Create: `cli/test/netbird/netbird.bats`
  - Integration tests for the `netbird` subcommand.
- Create: `cli/test/wg-client/netbird_config.bats`
  - Unit tests for `supervise_netbird_config` and `apply_netbird_peers`.
- Modify: `cli/test/init/init.bats`
  - Tests for `--netbird` flag plumbing.
- Modify: `cli/README.md`
  - Document `--netbird` init flag, settings key, and `sandcat netbird` subcommand.

---

### Task 1: Add the `netbird` sync container (Dockerfile + script + Compose)

**Files:**
- Create: `cli/templates/devcontainer/sandcat/Dockerfile.netbird`
- Create: `cli/templates/devcontainer/sandcat/scripts/netbird-sync.sh`
- Create: `cli/templates/devcontainer/sandcat/compose-netbird.yml`

- [ ] **Step 1: Write `Dockerfile.netbird`**

```dockerfile
# cli/templates/devcontainer/sandcat/Dockerfile.netbird
FROM debian:trixie-slim

# curl - NetBird management REST API calls
# jq   - parse API responses
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/netbird-sync.sh /usr/local/bin/netbird-sync.sh
RUN chmod +x /usr/local/bin/netbird-sync.sh

ENTRYPOINT ["/usr/local/bin/netbird-sync.sh"]
```

- [ ] **Step 2: Write `netbird-sync.sh`**

```bash
#!/bin/bash
# cli/templates/devcontainer/sandcat/scripts/netbird-sync.sh
#
# Polls the NetBird management API for the current peer list and writes
# a WireGuard syncconf-compatible peer config to /run/netbird/peers.conf.
# wg-client reads this file and applies it to wg0 via `wg syncconf`.
#
# Environment:
#   NB_MANAGEMENT_URL - NetBird management server base URL (default: https://api.netbird.io)
#   NB_API_TOKEN      - NetBird management API token (required)
#   NB_POLL_INTERVAL  - Seconds between polls (default: 5)
#
set -euo pipefail

PEERS_CONF="/run/netbird/peers.conf"
PEERS_CONF_TMP="${PEERS_CONF}.tmp"
NB_URL="${NB_MANAGEMENT_URL:-https://api.netbird.io}"
POLL_INTERVAL="${NB_POLL_INTERVAL:-5}"

if [[ -z "${NB_API_TOKEN:-}" ]]; then
    echo "NB_API_TOKEN is required" >&2
    exit 1
fi

mkdir -p "$(dirname "$PEERS_CONF")"

# Fetch the current peer list from NetBird management and write WireGuard
# peer stanzas to $1. Each peer entry from the API provides:
#   - public_key  : WireGuard public key
#   - ip          : allowed IP in the overlay (e.g. 100.64.0.1)
#   - routes      : additional CIDRs this peer serves (may be empty)
write_peers_conf() {
    local out="$1"
    local peers_json
    peers_json=$(curl -sf \
        -H "Authorization: Token $NB_API_TOKEN" \
        -H "Content-Type: application/json" \
        "$NB_URL/api/peers") || {
        echo "[netbird-sync] Failed to fetch peers from $NB_URL" >&2
        return 1
    }

    {
        echo "# Auto-generated by netbird-sync.sh — do not edit."
        echo "$peers_json" | jq -r '
            .[] | select(.connected == true) |
            "[Peer]\n" +
            "PublicKey = " + .public_key + "\n" +
            "AllowedIPs = " + (.ip + "/32," + (
                if .routes then (.routes | join(",")) else "" end
            ) | gsub(",+$"; "")) + "\n"
        '
    } > "$out"
}

main() {
    echo "[netbird-sync] Starting. Polling $NB_URL every ${POLL_INTERVAL}s."
    while true; do
        if write_peers_conf "$PEERS_CONF_TMP"; then
            if ! diff -q "$PEERS_CONF_TMP" "$PEERS_CONF" >/dev/null 2>&1; then
                mv "$PEERS_CONF_TMP" "$PEERS_CONF"
                echo "[netbird-sync] peers.conf updated."
            fi
        fi
        sleep "$POLL_INTERVAL"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

- [ ] **Step 3: Write `compose-netbird.yml`**

```yaml
# cli/templates/devcontainer/sandcat/compose-netbird.yml
services:
  netbird:
    build:
      context: .
      dockerfile: Dockerfile.netbird
    # No cap_add — this container only calls the NetBird management REST API
    # and writes a config file. It never touches network interfaces or iptables.
    environment:
      - NB_API_TOKEN
      - NB_MANAGEMENT_URL=https://api.netbird.io
      - NB_POLL_INTERVAL=5
    volumes:
      # Write-only: netbird-sync.sh writes peers.conf here.
      # wg-client mounts this volume read-only (see compose-proxy.yml).
      - netbird-config:/run/netbird
      # Read-only: CA cert for TLS verification when calling the management API.
      - mitmproxy-config:/mitmproxy-config:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "test -f /run/netbird/peers.conf"]
      interval: 5s
      timeout: 3s
      retries: 12

volumes:
  netbird-config:
```

- [ ] **Step 4: Validate both YAML files parse**

Run: `yq '.' cli/templates/devcontainer/sandcat/compose-netbird.yml`
Expected: YAML printed without errors.

- [ ] **Step 5: Commit**

```bash
git add \
    cli/templates/devcontainer/sandcat/Dockerfile.netbird \
    cli/templates/devcontainer/sandcat/scripts/netbird-sync.sh \
    cli/templates/devcontainer/sandcat/compose-netbird.yml
git commit -m "feat(netbird): add netbird sync container (Dockerfile, sync script, compose)"
```

---

### Task 2: Mount `netbird-config` in `wg-client` and add `inotify-tools` to its image

**Files:**
- Modify: `cli/templates/devcontainer/sandcat/compose-proxy.yml`
- Modify: `cli/templates/devcontainer/sandcat/Dockerfile.wg-client`

- [ ] **Step 1: Add `netbird-config` read-only volume mount to `wg-client` in `compose-proxy.yml`**

In the `wg-client` service `volumes` list, add:

```yaml
      # Read-only: peers.conf written by the netbird container.
      # wg-client watches this file and calls wg syncconf wg0 on change.
      - netbird-config:/run/netbird:ro
```

Also declare the external volume at the bottom of the file:

```yaml
volumes:
  mitmproxy-config:
  wg-runtime:
  netbird-config:
    external: true
```

(`external: true` because `netbird-config` is defined and owned by `compose-netbird.yml`.)

- [ ] **Step 2: Add `inotify-tools` to `Dockerfile.wg-client`**

Change the `apt-get install` line in `Dockerfile.wg-client` from:

```dockerfile
        wireguard-tools iproute2 iptables jq openresolv dnsmasq \
```

to:

```dockerfile
        wireguard-tools iproute2 iptables jq openresolv dnsmasq inotify-tools \
```

- [ ] **Step 3: Verify both files are valid**

Run: `yq '.' cli/templates/devcontainer/sandcat/compose-proxy.yml`
Expected: YAML printed without errors.

Run: `grep inotify cli/templates/devcontainer/sandcat/Dockerfile.wg-client`
Expected: Line with `inotify-tools` present.

- [ ] **Step 4: Commit**

```bash
git add \
    cli/templates/devcontainer/sandcat/compose-proxy.yml \
    cli/templates/devcontainer/sandcat/Dockerfile.wg-client
git commit -m "feat(netbird): mount netbird-config in wg-client and add inotify-tools"
```

---

### Task 3: Add `supervise_netbird_config` watcher to `wg-client-init.sh` with tests

**Files:**
- Modify: `cli/templates/devcontainer/sandcat/scripts/wg-client-init.sh`
- Create: `cli/test/wg-client/netbird_config.bats`

- [ ] **Step 1: Write the failing BATS tests**

```bash
# cli/test/wg-client/netbird_config.bats
#!/usr/bin/env bats

setup() {
    load test_helper
    PEERS_CONF="$BATS_TEST_TMPDIR/peers.conf"
    WG_IFACE="wg0"
}

teardown() {
    unstub_all
}

@test "apply_netbird_peers calls wg syncconf with peers.conf" {
    touch "$PEERS_CONF"
    stub wg \
        "syncconf wg0 $PEERS_CONF : :"
    apply_netbird_peers "$WG_IFACE" "$PEERS_CONF"
}

@test "apply_netbird_peers does nothing when peers.conf is absent" {
    run apply_netbird_peers "$WG_IFACE" "$BATS_TEST_TMPDIR/missing.conf"
    assert_success
}

@test "supervise_netbird_config returns immediately when netbird is not enabled" {
    # No peers.conf present and no inotifywait stub — function must return 0
    # without blocking.
    run supervise_netbird_config "$WG_IFACE" "$BATS_TEST_TMPDIR/missing.conf"
    assert_success
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd cli && bats test/wg-client/netbird_config.bats`
Expected: FAIL — `apply_netbird_peers` and `supervise_netbird_config` are not defined.

- [ ] **Step 3: Add the functions to `wg-client-init.sh`**

Add before the `main()` function:

```bash
# Apply the current NetBird peer config to the WireGuard interface.
# Uses `wg syncconf` so only the peer list changes; keys and listen port
# on wg0 (managed by main()) are untouched.
# Args:
#   $1 - WireGuard interface name (e.g. wg0)
#   $2 - Path to the peers.conf file written by the netbird container
apply_netbird_peers() {
    local iface=$1
    local peers_conf=$2
    [[ -f "$peers_conf" ]] || return 0
    wg syncconf "$iface" "$peers_conf"
}

# Watch peers.conf for changes and call apply_netbird_peers on each change.
# Returns immediately (no-op) if peers.conf does not exist, so this function
# is safe to call unconditionally regardless of whether NetBird is enabled.
# Args:
#   $1 - WireGuard interface name (e.g. wg0)
#   $2 - Path to the peers.conf file written by the netbird container
supervise_netbird_config() {
    local iface=$1
    local peers_conf=$2
    local peers_dir
    peers_dir=$(dirname "$peers_conf")

    [[ -f "$peers_conf" ]] || return 0

    echo "[wg-client] netbird peers.conf found; watching for changes."
    apply_netbird_peers "$iface" "$peers_conf"

    while inotifywait -e close_write -e moved_to "$peers_dir" >/dev/null 2>&1; do
        if [[ -f "$peers_conf" ]]; then
            echo "[wg-client] peers.conf changed; syncing wg0." >&2
            apply_netbird_peers "$iface" "$peers_conf"
        fi
    done
}
```

- [ ] **Step 4: Call `supervise_netbird_config` from `main()`**

In `main()`, find the `supervise_dnsmasq "$DNSMASQ_CONF"` call at the bottom. Replace it with a background call to `supervise_netbird_config` so both loops run concurrently:

```bash
    supervise_netbird_config wg0 "/run/netbird/peers.conf" &

    supervise_dnsmasq "$DNSMASQ_CONF"
```

(`supervise_dnsmasq` stays in the foreground so the container keeps running; the netbird watcher runs in the background.)

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `cd cli && bats test/wg-client/netbird_config.bats`
Expected: PASS.

- [ ] **Step 6: Run the existing wg-client tests to confirm nothing regressed**

Run: `cd cli && bats test/wg-client/`
Expected: PASS for all existing wg-client tests.

- [ ] **Step 7: Commit**

```bash
git add \
    cli/templates/devcontainer/sandcat/scripts/wg-client-init.sh \
    cli/test/wg-client/netbird_config.bats
git commit -m "feat(netbird): add supervise_netbird_config watcher to wg-client-init.sh"
```

---

### Task 4: Add `enable_netbird` compose function and tests

**Files:**
- Modify: `cli/lib/composefile.bash`
- Create: `cli/test/composefile/netbird.bats`

- [ ] **Step 1: Write the failing BATS test**

```bash
# cli/test/composefile/netbird.bats
#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/composefile.bash"

    COMPOSE_FILE="$BATS_TEST_TMPDIR/compose-all.yml"
    cat >"$COMPOSE_FILE" <<'YAML'
include:
  - path: sandcat/compose-proxy.yml
services:
  agent:
    image: placeholder
YAML
}

teardown() {
    unstub_all
}

@test "enable_netbird adds netbird include to compose-all.yml" {
    enable_netbird "$COMPOSE_FILE"

    yq -e '.include[] | select(.path == "sandcat/compose-netbird.yml")' "$COMPOSE_FILE"
}

@test "enable_netbird is idempotent" {
    enable_netbird "$COMPOSE_FILE"
    enable_netbird "$COMPOSE_FILE"

    run yq '[.include[] | select(.path == "sandcat/compose-netbird.yml")] | length' "$COMPOSE_FILE"
    assert_output "1"
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd cli && bats test/composefile/netbird.bats`
Expected: FAIL — `enable_netbird` is not defined.

- [ ] **Step 3: Implement `enable_netbird` in `cli/lib/composefile.bash`**

Add at the end of the file:

```bash
# Adds the NetBird compose include to compose-all.yml if not already present.
# Args:
#   $1 - Path to compose-all.yml
enable_netbird() {
    require yq
    local compose_file=$1

    local already_included
    already_included=$(yq '[.include[] | select(.path == "sandcat/compose-netbird.yml")] | length' "$compose_file")

    if [[ "$already_included" -eq 0 ]]; then
        yq -i '.include += [{"path": "sandcat/compose-netbird.yml"}]' "$compose_file"
    fi
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `cd cli && bats test/composefile/netbird.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cli/lib/composefile.bash cli/test/composefile/netbird.bats
git commit -m "feat(netbird): add enable_netbird compose helper with idempotency"
```

---

### Task 5: Add compose contract tests

**Files:**
- Create: `cli/test/composefile/netbird_contract.bats`

- [ ] **Step 1: Write the contract tests**

```bash
# cli/test/composefile/netbird_contract.bats
#!/usr/bin/env bats
#
# Verifies structural contracts between compose-netbird.yml, compose-proxy.yml,
# and compose-all.yml that security and integration correctness depend on.
#

setup() {
    load test_helper
    COMPOSE_NETBIRD="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-netbird.yml"
    COMPOSE_PROXY="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-proxy.yml"
    COMPOSE_ALL="$SCT_TEMPLATEDIR/devcontainer/compose-all.yml"
}

@test "netbird service has no cap_add entries" {
    run yq '.services.netbird.cap_add | length' "$COMPOSE_NETBIRD"
    # null (no cap_add key at all) or 0 are both acceptable
    [[ "$output" == "null" || "$output" == "0" ]]
}

@test "netbird service has NB_API_TOKEN in environment" {
    yq -e '.services.netbird.environment[] | select(. == "NB_API_TOKEN")' "$COMPOSE_NETBIRD"
}

@test "netbird service writes to netbird-config volume" {
    yq -e '.services.netbird.volumes[] | select(startswith("netbird-config:/run/netbird"))' "$COMPOSE_NETBIRD"
}

@test "netbird service has a healthcheck" {
    yq -e '.services.netbird.healthcheck' "$COMPOSE_NETBIRD"
}

@test "wg-client mounts netbird-config read-only" {
    yq -e '.services."wg-client".volumes[] | select(. == "netbird-config:/run/netbird:ro")' "$COMPOSE_PROXY"
}

@test "compose-all.yml does not include compose-netbird.yml by default" {
    run yq '.include[] | select(.path == "sandcat/compose-netbird.yml")' "$COMPOSE_ALL"
    assert_output ""
}
```

- [ ] **Step 2: Run the contract tests**

Run: `cd cli && bats test/composefile/netbird_contract.bats`
Expected: PASS for all six tests.

- [ ] **Step 3: Commit**

```bash
git add cli/test/composefile/netbird_contract.bats
git commit -m "test(netbird): add compose contract tests enforcing no-caps and volume separation"
```

---

### Task 6: Add NetBird management API helpers and unit tests

**Files:**
- Create: `cli/lib/netbird.bash`
- Create: `cli/test/netbird/test_helper.bash`
- Create: `cli/test/netbird/netbird_api.bats`

- [ ] **Step 1: Create the test helper**

```bash
# cli/test/netbird/test_helper.bash
#!/bin/bash
bats_require_minimum_version 1.5.0
if shopt -s compat32 2>/dev/null; then
    export BASH_COMPAT=3.2
fi
set -uo pipefail
export SHELLOPTS

SCT_ROOT="$BATS_TEST_DIRNAME/../.."
BATS_LIB_PATH="$SCT_ROOT/support":${BATS_LIB_PATH-}

bats_load_library bats-ext
bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-mock-ext

export SCT_ROOT SCT_LIBDIR="$SCT_ROOT/lib"
```

- [ ] **Step 2: Write the failing unit tests**

```bash
# cli/test/netbird/netbird_api.bats
#!/usr/bin/env bats

setup() {
    load test_helper
    source "$SCT_LIBDIR/netbird.bash"

    export NB_MANAGEMENT_URL="https://api.netbird.io"
    export NB_API_TOKEN="test-token"
}

teardown() {
    unstub_all
}

@test "netbird_api fails when NB_API_TOKEN is unset" {
    unset NB_API_TOKEN
    run netbird_api "GET" "/api/peers"
    assert_failure
    assert_output --partial "NB_API_TOKEN"
}

@test "netbird_status calls GET /api/peers" {
    stub curl \
        "-sf -X GET -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[{\"id\":\"peer1\",\"connected\":true}]'"
    run netbird_status
    assert_success
    assert_output --partial "peer1"
}

@test "netbird_route_add calls POST /api/routes with network and peer" {
    stub curl \
        "-sf -X POST -H 'Authorization: Token test-token' -H 'Content-Type: application/json' -d '{\"network\":\"10.8.0.0/24\",\"peer\":\"peer1\",\"enabled\":true}' https://api.netbird.io/api/routes : echo '{\"id\":\"route1\"}'"
    run netbird_route_add "10.8.0.0/24" "peer1"
    assert_success
}

@test "netbird_route_remove calls DELETE /api/routes/:id" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/routes/route1 : :"
    run netbird_route_remove "route1"
    assert_success
}

@test "netbird_peer_remove calls DELETE /api/peers/:id" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers/peer1 : :"
    run netbird_peer_remove "peer1"
    assert_success
}
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `cd cli && bats test/netbird/netbird_api.bats`
Expected: FAIL — `cli/lib/netbird.bash` does not exist.

- [ ] **Step 4: Implement `cli/lib/netbird.bash`**

```bash
# cli/lib/netbird.bash
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
# Causes netbird-sync.sh to write an updated peers.conf that omits this peer,
# which wg-client then applies via wg syncconf — removing the route to that peer.
# Args:
#   $1 - Peer ID
netbird_peer_remove() {
    local peer_id=$1
    netbird_api "DELETE" "/api/peers/$peer_id"
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `cd cli && bats test/netbird/netbird_api.bats`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add cli/lib/netbird.bash cli/test/netbird/test_helper.bash cli/test/netbird/netbird_api.bats
git commit -m "feat(netbird): add netbird management API helpers with unit tests"
```

---

### Task 7: Add `sandcat netbird` subcommand dispatcher and integration tests

**Files:**
- Create: `cli/libexec/netbird/netbird`
- Create: `cli/test/netbird/netbird.bats`

- [ ] **Step 1: Write the failing integration tests**

```bash
# cli/test/netbird/netbird.bats
#!/usr/bin/env bats

setup() {
    load test_helper

    NETBIRD_CMD="$SCT_LIBEXECDIR/netbird/netbird"
    export NB_MANAGEMENT_URL="https://api.netbird.io"
    export NB_API_TOKEN="test-token"
}

teardown() {
    unstub_all
}

@test "netbird status calls GET /api/peers" {
    stub curl \
        "-sf -X GET -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[]'"
    run bash "$NETBIRD_CMD" status
    assert_success
}

@test "netbird peer remove requires --peer-id" {
    run bash "$NETBIRD_CMD" peer remove
    assert_failure
    assert_output --partial "peer-id"
}

@test "netbird peer remove calls netbird_peer_remove" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers/abc123 : :"
    run bash "$NETBIRD_CMD" peer remove --peer-id abc123
    assert_success
}

@test "netbird route add requires --network and --peer-id" {
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24
    assert_failure
    assert_output --partial "peer-id"
}

@test "netbird route add calls netbird_route_add" {
    stub curl \
        "-sf -X POST -H 'Authorization: Token test-token' -H 'Content-Type: application/json' -d '{\"network\":\"10.8.0.0/24\",\"peer\":\"abc123\",\"enabled\":true}' https://api.netbird.io/api/routes : echo '{\"id\":\"route1\"}'"
    run bash "$NETBIRD_CMD" route add --network 10.8.0.0/24 --peer-id abc123
    assert_success
}

@test "netbird route remove requires --route-id" {
    run bash "$NETBIRD_CMD" route remove
    assert_failure
    assert_output --partial "route-id"
}

@test "netbird route remove calls netbird_route_remove" {
    stub curl \
        "-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/routes/route1 : :"
    run bash "$NETBIRD_CMD" route remove --route-id route1
    assert_success
}

@test "netbird with unknown subcommand prints usage and fails" {
    run bash "$NETBIRD_CMD" bogus
    assert_failure
    assert_output --partial "Usage"
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd cli && bats test/netbird/netbird.bats`
Expected: FAIL — `cli/libexec/netbird/netbird` does not exist.

- [ ] **Step 3: Create the dispatcher**

```bash
#!/usr/bin/env bash
# cli/libexec/netbird/netbird
set -euo pipefail

# shellcheck source=../../lib/logging.bash
source "$SCT_LIBDIR/logging.bash"
# shellcheck source=../../lib/netbird.bash
source "$SCT_LIBDIR/netbird.bash"

usage() {
    cat <<'EOF'
Usage: sandcat netbird <subcommand> [options]

Subcommands:
  status                                    List peers from the NetBird management server
  peer remove --peer-id <id>                Remove a peer (triggers wg syncconf in wg-client)
  route add   --network <cidr> --peer-id <id>   Add a network route
  route remove --route-id <id>              Remove a route by ID
EOF
}

cmd_status() {
    netbird_status
}

cmd_peer() {
    local subcmd="${1:-}"
    shift || true
    case "$subcmd" in
    remove)
        local peer_id=""
        while [[ $# -gt 0 ]]; do
            case $1 in
            --peer-id) peer_id="$2"; shift 2 ;;
            *) echo "Unknown option: $1" | error; return 1 ;;
            esac
        done
        if [[ -z "$peer_id" ]]; then
            echo "Missing required option: --peer-id" | error; return 1
        fi
        netbird_peer_remove "$peer_id"
        ;;
    *)
        echo "Unknown peer subcommand: $subcmd" | error
        usage; return 1
        ;;
    esac
}

cmd_route() {
    local subcmd="${1:-}"
    shift || true
    case "$subcmd" in
    add)
        local network="" peer_id=""
        while [[ $# -gt 0 ]]; do
            case $1 in
            --network) network="$2"; shift 2 ;;
            --peer-id) peer_id="$2"; shift 2 ;;
            *) echo "Unknown option: $1" | error; return 1 ;;
            esac
        done
        if [[ -z "$network" ]]; then
            echo "Missing required option: --network" | error; return 1
        fi
        if [[ -z "$peer_id" ]]; then
            echo "Missing required option: --peer-id" | error; return 1
        fi
        netbird_route_add "$network" "$peer_id"
        ;;
    remove)
        local route_id=""
        while [[ $# -gt 0 ]]; do
            case $1 in
            --route-id) route_id="$2"; shift 2 ;;
            *) echo "Unknown option: $1" | error; return 1 ;;
            esac
        done
        if [[ -z "$route_id" ]]; then
            echo "Missing required option: --route-id" | error; return 1
        fi
        netbird_route_remove "$route_id"
        ;;
    *)
        echo "Unknown route subcommand: $subcmd" | error
        usage; return 1
        ;;
    esac
}

main() {
    local subcmd="${1:-}"
    shift || true
    case "$subcmd" in
    status) cmd_status "$@" ;;
    peer)   cmd_peer "$@" ;;
    route)  cmd_route "$@" ;;
    *)
        usage
        return 1
        ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x cli/libexec/netbird/netbird`

- [ ] **Step 5: Run the integration tests to confirm they pass**

Run: `cd cli && bats test/netbird/netbird.bats`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add cli/libexec/netbird/netbird cli/test/netbird/netbird.bats
git commit -m "feat(netbird): add sandcat netbird subcommand dispatcher"
```

---

### Task 8: Wire `--netbird` flag into `init devcontainer` and `init`

**Files:**
- Modify: `cli/libexec/init/devcontainer`
- Modify: `cli/libexec/init/init`
- Modify: `cli/test/init/init.bats`

- [ ] **Step 1: Write the failing BATS tests**

Add to `cli/test/init/init.bats`:

```bash
@test "init --netbird passes netbird flag to devcontainer" {
    stub devcontainer \
        "--settings-file .sandcat/settings.json --project-path * --agent claude --ide vscode --name test --stacks * --proxy web --secret-provider none --netbird : :"
    run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --netbird
    assert_success
}

@test "init --netbird seeds netbird_enrollment_key in user settings" {
    stub devcontainer "*: :"
    run init --agent claude --ide vscode --name test --path "$PROJECT_DIR" --stacks "" --netbird
    run yq '.netbird_enrollment_key' "$SCT_HOME_DIR/settings.json"
    assert_output '""'
}
```

- [ ] **Step 2: Run targeted tests to confirm they fail**

Run: `cd cli && bats test/init/init.bats --filter "netbird"`
Expected: FAIL — `--netbird` is not recognized.

- [ ] **Step 3: Add `--netbird` to `cli/libexec/init/devcontainer`**

Add `local netbird="false"` at the top of the function alongside the other locals.

In the argument-parsing loop add:

```bash
--netbird)
    netbird="true"
    shift 1
    ;;
```

After the `apply_secret_provider` call, add:

```bash
if [[ "$netbird" == "true" ]]; then
    enable_netbird "$compose_file"
fi
```

- [ ] **Step 4: Add `--netbird` to `cli/libexec/init/init`**

Add `local netbird="false"` near the other locals. In the argument-parsing loop add:

```bash
--netbird)
    netbird="true"
    shift 1
    ;;
```

Where provider tokens are seeded into user settings, add alongside:

```bash
if [[ "$netbird" == "true" ]]; then
    yq -i -o json '.netbird_enrollment_key = (.netbird_enrollment_key // "")' "$user_settings_file"
fi
```

In the `devcontainer` invocation, append:

```bash
devcontainer \
    --settings-file "$rel_settings_file" \
    ... \
    --secret-provider "$secret_provider" \
    ${netbird:+--netbird}
```

- [ ] **Step 5: Run all init tests**

Run: `cd cli && bats test/init/init.bats`
Expected: PASS for all existing and new tests.

- [ ] **Step 6: Commit**

```bash
git add cli/libexec/init/devcontainer cli/libexec/init/init cli/test/init/init.bats
git commit -m "feat(init): add --netbird flag and enrollment key seeding"
```

---

### Task 9: Update CLI docs

**Files:**
- Modify: `cli/README.md`

- [ ] **Step 1: Add `--netbird` option description after `--secret-provider`**

```markdown
- `--netbird` - Enable dynamic WireGuard control via NetBird. Adds a companion
  `netbird` sync container that polls the NetBird management API and updates
  `wg-client`'s peer table without restarting any container.
  Seeds `netbird_enrollment_key` in `~/.config/sandcat/settings.json`.
```

- [ ] **Step 2: Add init usage example**

```bash
# With NetBird dynamic WireGuard
sandcat init --agent claude --ide vscode --netbird --name myproject
```

- [ ] **Step 3: Add `## Dynamic networking (NetBird)` section**

```markdown
## Dynamic networking (NetBird)

When initialized with `--netbird`, sandcat adds a companion NetBird sync container.
It polls the [NetBird](https://netbird.io) management API, writes a WireGuard peer
config file, and `wg-client` applies it via `wg syncconf` — no container restarts.

The `netbird` container has no kernel capabilities and does not manage any network
interfaces. `wg-client` remains the sole owner of `NET_ADMIN` and `wg0`.

### Setup

1. Create a NetBird account at <https://app.netbird.io> or self-host the server.
2. Generate a setup key (**Setup Keys** in the NetBird dashboard).
3. Generate an API token (**API Keys** in the NetBird dashboard).
4. Add both to your sandcat user settings:

```json
{
  "netbird_enrollment_key": "your-setup-key-here"
}
```

5. Export the API token in your shell before using `sandcat netbird` commands:

```bash
export NB_API_TOKEN="your-api-token"
export NB_MANAGEMENT_URL="https://api.netbird.io"  # or self-hosted URL
```

### Runtime control

```bash
# List current peers
sandcat netbird status

# Remove a peer (wg-client drops the route within one poll interval)
sandcat netbird peer remove --peer-id <peer-id>

# Add a network route served by a peer
sandcat netbird route add --network 10.8.0.0/24 --peer-id <peer-id>

# Remove a route
sandcat netbird route remove --route-id <route-id>
```
```

- [ ] **Step 4: Verify**

Run: `rg --line-number "netbird" cli/README.md`
Expected: Only the newly added lines.

- [ ] **Step 5: Commit**

```bash
git add cli/README.md
git commit -m "docs(cli): document --netbird flag and sandcat netbird subcommand"
```

---

### Task 10: Final verification

**Files:** None modified.

- [ ] **Step 1: Run full composefile suite**

Run: `cd cli && bats test/composefile/`
Expected: PASS.

- [ ] **Step 2: Run full netbird suite**

Run: `cd cli && bats test/netbird/`
Expected: PASS.

- [ ] **Step 3: Run full wg-client suite**

Run: `cd cli && bats test/wg-client/`
Expected: PASS including `netbird_config.bats`.

- [ ] **Step 4: Run full init suite**

Run: `cd cli && bats test/init/`
Expected: PASS.

- [ ] **Step 5: Confirm clean git state**

Run: `git status --short`
Expected: No untracked or modified files.

- [ ] **Step 6: Confirm all commits are present**

Run: `git log --oneline -12`
Expected: One commit per task with descriptive messages.

---

## Plan Self-Review

### 1. Spec coverage

| Requirement | Task |
|---|---|
| `netbird` container (no caps, config-sync only) | 1 |
| `Dockerfile.netbird` + `netbird-sync.sh` | 1 |
| `wg-client` mounts `netbird-config` read-only | 2 |
| `inotify-tools` in `wg-client` image | 2 |
| `supervise_netbird_config` + `apply_netbird_peers` | 3 |
| `enable_netbird` compose helper | 4 |
| Contract tests (no caps, read-only mount, no default include) | 5 |
| Management API helpers | 6 |
| `sandcat netbird` dispatcher | 7 |
| `--netbird` flag in `init` and `init devcontainer` | 8 |
| `netbird_enrollment_key` seeded in user settings | 8 |
| README docs | 9 |

No gaps.

### 2. Placeholder scan

No TBD/TODO in any step. All code blocks are complete.

### 3. Type/name consistency

- `NB_API_TOKEN` — used in `netbird-sync.sh`, `netbird.bash`, dispatcher, contract test, README.
- `NB_MANAGEMENT_URL` — same propagation path.
- `NB_SETUP_KEY` is absent from the compose definition by design: enrollment is handled by the user populating `netbird_enrollment_key` in settings; the sync container only uses the API token.
- `netbird-config` volume name — used consistently in `compose-netbird.yml`, `compose-proxy.yml`, and contract tests.
- `/run/netbird/peers.conf` — the agreed path between `netbird-sync.sh` (writer) and `wg-client-init.sh` (reader), tested in `netbird_contract.bats` and `netbird_config.bats`.

### 4. Security properties preserved

- `wg-client` is the only container with `NET_ADMIN`. The contract test asserts no `cap_add` on the `netbird` service.
- `netbird-config` volume is writable only by `netbird`, read-only for `wg-client`. The contract test asserts the `:ro` mount.
- `netbird` has no access to `wg0`, iptables, or the mitmproxy tunnel — it only writes a text file.

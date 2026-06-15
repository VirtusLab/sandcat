# NetBird Dynamic WireGuard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a NetBird client container to sandcat's proxy stack so that the WireGuard network layer becomes dynamically controllable at runtime — enabling routes and peer access to be added or removed without restarting any container.

**Architecture:** A new `netbird` service runs as a companion to `wg-client` in `compose-proxy.yml`. It connects to a NetBird management server (self-hosted or NetBird Cloud) using an enrollment key from user settings. `wg-client-init.sh` continues to manage the mitmproxy WireGuard tunnel unchanged; NetBird owns a separate `wg` interface (`wgnetbird`) that provides the dynamic overlay network. The `sandcat netbird` CLI subcommand surfaces `up`, `down`, `route add`, `route remove`, and `status` for runtime control via the NetBird management API (no container restarts required). This is pure infrastructure — no research instrumentation in this plan.

**Tech Stack:** Bash (`bats`, `bats-mock-ext`, `yq`), Docker Compose, NetBird client Docker image (`netbirdio/netbird`), NetBird management REST API (v1).

---

## File Structure and Responsibilities

- Create: `cli/templates/devcontainer/sandcat/compose-netbird.yml`
  - Defines the `netbird` service: image, volumes, caps, env, healthcheck.
- Modify: `cli/templates/devcontainer/compose-all.yml`
  - Add `include` for `compose-netbird.yml` (opt-in; only included when NetBird is enabled).
- Modify: `cli/lib/composefile.bash`
  - Add `enable_netbird` function that patches `compose-all.yml` to include `compose-netbird.yml`.
- Modify: `cli/libexec/init/devcontainer`
  - Accept `--netbird` flag; call `enable_netbird` when present.
- Modify: `cli/libexec/init/init`
  - Add `--netbird` flag; seed `netbird_enrollment_key` in user settings when flag is set; pass flag to `devcontainer`.
- Create: `cli/libexec/netbird/netbird`
  - Subcommand dispatcher: `up`, `down`, `route`, `status` — all implemented as calls to the NetBird management REST API via `curl` + the enrollment key from settings.
- Create: `cli/lib/netbird.bash`
  - Pure helper functions: `netbird_api`, `netbird_up`, `netbird_down`, `netbird_route_add`, `netbird_route_remove`, `netbird_status`. All testable without Docker.
- Modify: `cli/libexec/init/settings`
  - Add `netbird_enrollment_key` field handling.
- Create: `cli/test/composefile/netbird.bats`
  - Tests for `enable_netbird` function.
- Create: `cli/test/netbird/test_helper.bash`
  - Standard test setup for netbird tests.
- Create: `cli/test/netbird/netbird_api.bats`
  - Unit tests for `netbird.bash` helper functions.
- Create: `cli/test/netbird/netbird.bats`
  - Integration tests for the `netbird` subcommand dispatcher.
- Modify: `cli/test/init/init.bats`
  - Add tests for `--netbird` flag plumbing.
- Modify: `cli/README.md`
  - Document `--netbird` init flag, settings key, and `sandcat netbird` subcommand.

---

### Task 1: Add `netbird` service Compose definition

**Files:**
- Create: `cli/templates/devcontainer/sandcat/compose-netbird.yml`

- [ ] **Step 1: Write the compose service definition**

```yaml
# cli/templates/devcontainer/sandcat/compose-netbird.yml
services:
  netbird:
    image: netbirdio/netbird:latest
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE
    environment:
      - NB_SETUP_KEY
    volumes:
      - netbird-config:/etc/netbird
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "netbird", "status"]
      interval: 5s
      timeout: 5s
      retries: 12

volumes:
  netbird-config:
```

- [ ] **Step 2: Validate the file parses correctly**

Run: `yq '.' cli/templates/devcontainer/sandcat/compose-netbird.yml`
Expected: YAML printed without errors.

- [ ] **Step 3: Commit**

```bash
git add cli/templates/devcontainer/sandcat/compose-netbird.yml
git commit -m "feat(netbird): add netbird service compose definition"
```

---

### Task 2: Add `enable_netbird` compose function and tests

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

### Task 3: Add NetBird pure API helpers and unit tests

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

@test "netbird_api calls curl with auth header and endpoint" {
	stub curl \
		"-sf -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '{\"peers\":[]}\n'"
	run netbird_api "GET" "/api/peers"
	assert_success
}

@test "netbird_api fails when NB_API_TOKEN is unset" {
	unset NB_API_TOKEN
	run netbird_api "GET" "/api/peers"
	assert_failure
	assert_output --partial "NB_API_TOKEN"
}

@test "netbird_status returns structured peer list" {
	stub curl \
		"-sf -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[{\"id\":\"peer1\",\"name\":\"test\",\"connected\":true}]'"
	run netbird_status
	assert_success
	assert_output --partial "peer1"
}

@test "netbird_route_add calls routes API with network and peer" {
	stub curl \
		"-sf -X POST -H 'Authorization: Token test-token' -H 'Content-Type: application/json' -d '{\"network\":\"10.8.0.0/24\",\"peer\":\"peer1\",\"enabled\":true}' https://api.netbird.io/api/routes : echo '{\"id\":\"route1\"}'"
	run netbird_route_add "10.8.0.0/24" "peer1"
	assert_success
}

@test "netbird_route_remove calls DELETE on routes API" {
	stub curl \
		"-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/routes/route1 : :"
	run netbird_route_remove "route1"
	assert_success
}

@test "netbird_up calls peers API to enable peer" {
	stub curl \
		"-sf -X PUT -H 'Authorization: Token test-token' -H 'Content-Type: application/json' -d '{\"login_expiration_enabled\":false}' https://api.netbird.io/api/peers/peer1 : echo '{\"id\":\"peer1\"}'"
	run netbird_up "peer1"
	assert_success
}

@test "netbird_down calls peers API to disable peer" {
	stub curl \
		"-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers/peer1 : :"
	run netbird_down "peer1"
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
# Requires NB_MANAGEMENT_URL and NB_API_TOKEN to be set in the environment.
# Args:
#   $1 - HTTP method (GET, POST, PUT, DELETE)
#   $2 - API path (e.g. /api/peers)
#   $3 - Optional JSON body string
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

	if [[ -n "$body" ]]; then
		args+=(-d "$body")
	fi

	curl "${args[@]}" "$url"
}

# Returns the current list of peers from the NetBird management server.
netbird_status() {
	netbird_api "GET" "/api/peers"
}

# Enables a peer by ID on the NetBird management server.
# Args:
#   $1 - Peer ID
netbird_up() {
	local peer_id=$1
	netbird_api "PUT" "/api/peers/$peer_id" '{"login_expiration_enabled":false}'
}

# Removes a peer by ID from the NetBird management server.
# Args:
#   $1 - Peer ID
netbird_down() {
	local peer_id=$1
	netbird_api "DELETE" "/api/peers/$peer_id"
}

# Adds a network route to the NetBird management server.
# Args:
#   $1 - Network CIDR (e.g. 10.8.0.0/24)
#   $2 - Peer ID that serves the route
netbird_route_add() {
	local network=$1
	local peer_id=$2
	netbird_api "POST" "/api/routes" "{\"network\":\"$network\",\"peer\":\"$peer_id\",\"enabled\":true}"
}

# Removes a network route by ID from the NetBird management server.
# Args:
#   $1 - Route ID
netbird_route_remove() {
	local route_id=$1
	netbird_api "DELETE" "/api/routes/$route_id"
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `cd cli && bats test/netbird/netbird_api.bats`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add cli/lib/netbird.bash cli/test/netbird/test_helper.bash cli/test/netbird/netbird_api.bats
git commit -m "feat(netbird): add pure netbird API helpers with unit tests"
```

---

### Task 4: Add `sandcat netbird` subcommand dispatcher and integration tests

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

@test "netbird status calls netbird_status" {
	stub curl \
		"-sf -X GET -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers : echo '[]'"
	run bash "$NETBIRD_CMD" status
	assert_success
}

@test "netbird up requires peer-id argument" {
	run bash "$NETBIRD_CMD" up
	assert_failure
	assert_output --partial "peer-id"
}

@test "netbird up calls netbird_up with peer-id" {
	stub curl \
		"-sf -X PUT -H 'Authorization: Token test-token' -H 'Content-Type: application/json' -d '{\"login_expiration_enabled\":false}' https://api.netbird.io/api/peers/abc123 : echo '{\"id\":\"abc123\"}'"
	run bash "$NETBIRD_CMD" up --peer-id abc123
	assert_success
}

@test "netbird down requires peer-id argument" {
	run bash "$NETBIRD_CMD" down
	assert_failure
	assert_output --partial "peer-id"
}

@test "netbird down calls netbird_down with peer-id" {
	stub curl \
		"-sf -X DELETE -H 'Authorization: Token test-token' -H 'Content-Type: application/json' https://api.netbird.io/api/peers/abc123 : :"
	run bash "$NETBIRD_CMD" down --peer-id abc123
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
  status                          List connected NetBird peers
  up   --peer-id <id>             Enable a peer on the NetBird management server
  down --peer-id <id>             Remove a peer from the NetBird management server
  route add  --network <cidr> --peer-id <id>   Add a route
  route remove --route-id <id>                  Remove a route by ID
EOF
}

cmd_status() {
	netbird_status
}

cmd_up() {
	local peer_id=""
	while [[ $# -gt 0 ]]; do
		case $1 in
		--peer-id) peer_id="$2"; shift 2 ;;
		*) echo "Unknown option: $1" | error; return 1 ;;
		esac
	done
	if [[ -z "$peer_id" ]]; then
		echo "Missing required option: --peer-id" | error
		return 1
	fi
	netbird_up "$peer_id"
}

cmd_down() {
	local peer_id=""
	while [[ $# -gt 0 ]]; do
		case $1 in
		--peer-id) peer_id="$2"; shift 2 ;;
		*) echo "Unknown option: $1" | error; return 1 ;;
		esac
	done
	if [[ -z "$peer_id" ]]; then
		echo "Missing required option: --peer-id" | error
		return 1
	fi
	netbird_down "$peer_id"
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
	up)     cmd_up "$@" ;;
	down)   cmd_down "$@" ;;
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

### Task 5: Wire `--netbird` flag into `init devcontainer` and `init`

**Files:**
- Modify: `cli/libexec/init/devcontainer`
- Modify: `cli/libexec/init/init`
- Modify: `cli/test/init/init.bats`

- [ ] **Step 1: Write the failing BATS tests for the new flags**

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

- [ ] **Step 2: Run the targeted tests to confirm they fail**

Run: `cd cli && bats test/init/init.bats --filter "netbird"`
Expected: FAIL — `--netbird` is not recognized by `init`.

- [ ] **Step 3: Add `--netbird` to `cli/libexec/init/devcontainer`**

In the `while [[ $# -gt 0 ]]` argument-parsing loop, add:

```bash
--netbird)
    netbird="true"
    shift 1
    ;;
```

Add `local netbird="false"` at the top of the function alongside the other locals. After the `apply_secret_provider` call, add:

```bash
if [[ "$netbird" == "true" ]]; then
    enable_netbird "$compose_file"
fi
```

Also add `--netbird` to the case branch that checks for options requiring values:

```bash
--settings-file|--project-path|--agent|--ide|--name|--stacks|--proxy|--secret-provider)
```

becomes:

```bash
--settings-file|--project-path|--agent|--ide|--name|--stacks|--proxy|--secret-provider)
```

`--netbird` takes no value so it stays outside that branch.

- [ ] **Step 4: Add `--netbird` to `cli/libexec/init/init`**

Add `local netbird="false"` near the other locals. In the argument-parsing loop add:

```bash
--netbird)
    netbird="true"
    shift 1
    ;;
```

In the `add_secret_provider_tokens_to_user_settings` call site, add alongside it:

```bash
if [[ "$netbird" == "true" ]]; then
    yq -i -o json '.netbird_enrollment_key = (.netbird_enrollment_key // "")' "$user_settings_file"
fi
```

In the `devcontainer` invocation, append `${netbird:+--netbird}`:

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

### Task 6: Add compose contract tests for the netbird include

**Files:**
- Create: `cli/test/composefile/netbird_contract.bats`

- [ ] **Step 1: Write the contract tests**

```bash
# cli/test/composefile/netbird_contract.bats
#!/usr/bin/env bats
#
# Verifies that compose-netbird.yml and compose-all.yml meet structural contracts
# that other components rely on.
#

setup() {
	load test_helper
	COMPOSE_NETBIRD="$SCT_TEMPLATEDIR/devcontainer/sandcat/compose-netbird.yml"
	COMPOSE_ALL="$SCT_TEMPLATEDIR/devcontainer/compose-all.yml"
}

@test "compose-netbird.yml defines netbird service" {
	yq -e '.services.netbird' "$COMPOSE_NETBIRD"
}

@test "compose-netbird.yml netbird service has NET_ADMIN capability" {
	yq -e '.services.netbird.cap_add[] | select(. == "NET_ADMIN")' "$COMPOSE_NETBIRD"
}

@test "compose-netbird.yml netbird service has NB_SETUP_KEY environment entry" {
	yq -e '.services.netbird.environment[] | select(. == "NB_SETUP_KEY")' "$COMPOSE_NETBIRD"
}

@test "compose-netbird.yml netbird service has healthcheck" {
	yq -e '.services.netbird.healthcheck' "$COMPOSE_NETBIRD"
}

@test "compose-netbird.yml netbird service uses netbird-config named volume" {
	yq -e '.volumes.netbird-config' "$COMPOSE_NETBIRD"
}

@test "compose-all.yml does not include compose-netbird.yml by default" {
	run yq '.include[] | select(.path == "sandcat/compose-netbird.yml")' "$COMPOSE_ALL"
	assert_output ""
}
```

- [ ] **Step 2: Run the contract tests**

Run: `cd cli && bats test/composefile/netbird_contract.bats`
Expected: PASS. (The last test verifies the template ships without NetBird by default.)

- [ ] **Step 3: Commit**

```bash
git add cli/test/composefile/netbird_contract.bats
git commit -m "test(netbird): add compose contract tests for netbird service"
```

---

### Task 7: Update CLI docs

**Files:**
- Modify: `cli/README.md`

- [ ] **Step 1: Add NetBird section to README**

Locate the `--secret-provider` option description in `cli/README.md` and add immediately after it:

```markdown
- `--netbird` - Enable dynamic WireGuard control via NetBird. Adds a companion
  `netbird` container to the proxy stack and seeds `netbird_enrollment_key` in
  your user settings (`~/.config/sandcat/settings.json`). Fill in the key before
  starting the devcontainer.
```

Find the init usage examples and add:

```bash
# With NetBird dynamic WireGuard
sandcat init --agent claude --ide vscode --netbird --name myproject
```

Add a new section `## Dynamic networking (NetBird)`:

```markdown
## Dynamic networking (NetBird)

When initialized with `--netbird`, sandcat adds a companion [NetBird](https://netbird.io)
container that connects to a NetBird management server. This makes the WireGuard
network layer controllable at runtime — routes and peer access can be added or
removed without restarting any container.

### Setup

1. Create a NetBird account at <https://app.netbird.io> or self-host the management server.
2. Generate a setup key in the NetBird dashboard under **Setup Keys**.
3. Add the key to your sandcat user settings:

```json
{
  "netbird_enrollment_key": "your-setup-key-here"
}
```

4. Set the NetBird API token in your shell before using `sandcat netbird` commands:

```bash
export NB_API_TOKEN="your-management-api-token"
export NB_MANAGEMENT_URL="https://api.netbird.io"  # or your self-hosted URL
```

### Runtime control

```bash
# List connected peers
sandcat netbird status

# Enable a peer
sandcat netbird up --peer-id <peer-id>

# Remove a peer
sandcat netbird down --peer-id <peer-id>

# Add a network route served by a peer
sandcat netbird route add --network 10.8.0.0/24 --peer-id <peer-id>

# Remove a route by ID (ID returned by route add)
sandcat netbird route remove --route-id <route-id>
```
```

- [ ] **Step 2: Verify no old NetBird references remain undefined**

Run: `rg --line-number "netbird" cli/README.md`
Expected: Only the newly added lines appear.

- [ ] **Step 3: Commit**

```bash
git add cli/README.md
git commit -m "docs(cli): document --netbird flag and sandcat netbird subcommand"
```

---

### Task 8: Final verification

**Files:** None modified (verification only).

- [ ] **Step 1: Run full composefile test suite**

Run: `cd cli && bats test/composefile/`
Expected: PASS (all composefile tests including new netbird tests).

- [ ] **Step 2: Run full netbird test suite**

Run: `cd cli && bats test/netbird/`
Expected: PASS.

- [ ] **Step 3: Run full init test suite**

Run: `cd cli && bats test/init/`
Expected: PASS.

- [ ] **Step 4: Confirm git status is clean**

Run: `git status --short`
Expected: No untracked or modified files.

- [ ] **Step 5: Confirm all new files are committed**

Run: `git log --oneline -8`
Expected: All tasks committed individually with descriptive messages.

---

## Plan Self-Review

### 1. Spec coverage check

| Requirement | Covered by |
|---|---|
| NetBird companion container definition | Task 1 |
| `enable_netbird` compose helper | Task 2 |
| Pure API helpers (status, up, down, route add/remove) | Task 3 |
| `sandcat netbird` subcommand dispatcher | Task 4 |
| `--netbird` flag in `init` and `init devcontainer` | Task 5 |
| `netbird_enrollment_key` seeded in user settings | Task 5 |
| Compose contract tests (no default include) | Task 6 |
| README docs | Task 7 |

No spec gaps.

### 2. Placeholder scan

No TBD/TODO in any step. Every code step contains concrete implementations. Every run step contains expected output.

### 3. Type/name consistency

- `NB_API_TOKEN` and `NB_MANAGEMENT_URL` used consistently across `netbird.bash`, the dispatcher, and README.
- `NB_SETUP_KEY` (container enrollment env var) is distinct from `NB_API_TOKEN` (management API token) — both are explicitly named throughout.
- `enable_netbird` called consistently from `composefile.bash` and `init devcontainer`.
- `netbird_enrollment_key` (settings JSON key) used consistently in `init` and README.

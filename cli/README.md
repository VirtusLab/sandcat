# Sandcat CLI

Command-line tool for managing sandcat configurations and Docker Compose setups.

Requires `docker` (and `docker compose`) and [`yq`](https://github.com/mikefarah/yq).

## Modules and Commands

### `sandcat init`

Initializes sandcat for a project. Prompts for any options not provided via flags, then sets up the necessary
configuration files and network settings. Optional volume mounts (agent config, .git, .idea) are included as
commented-out entries in the generated compose file (agent config defaults to active for the selected agent).

Options:
- `--agent` - Agent type: `claude`, `cursor` (skips prompt)
- `--ide` - IDE for devcontainer mode: `vscode`, `jetbrains`, `none` (skips prompt)
- `--stacks` - Comma-separated development stacks to install: `node`, `python`, `java`, `rust`, `go`, `scala`, `ruby`, `dotnet`, `zig` (skips prompt)
- `--proxy` - Proxy UI mode: `web` (default, mitmweb browser UI) or `tui` (mitmproxy console, use with `sandcat proxy` to attach)
- `--secret-provider` / `--sp` - Secret backend: `none` (default), `1password`, `protonpass` (skips prompt when set)
- `--netbird` - Enable dynamic WireGuard control via NetBird. The NetBird client
  daemon runs inside the **mitmproxy** container and manages `wt0` — a second
  WireGuard interface for the NetBird overlay mesh. Agent egress always flows
  `wg0 (wg-client) → mitmproxy L7 inspect → internet or wt0 mesh`, so all
  traffic — including mesh traffic — is subject to mitmproxy network rules and
  secret substitution. Seeds `netbird_enrollment_key` and `netbird_api_token`
  in `~/.config/sandcat/settings.json`.
- `--capability` - Enable the capability-runtime sidecar (requires `--netbird`).
  Adds a `capability-runtime` compose service, mounts a shared Unix socket volume
  into the agent container, and installs `capability-mcp-bridge` for Cursor MCP.
  NetBird API credentials stay in the sidecar — they are not injected into the agent.
- `--netbird-management-url` - Existing NetBird management server URL (requires
  `--netbird`). Omit to use NetBird Cloud (`https://api.netbird.io`). Sandcat
  does not create or start a management server; see
  [`docs/examples/netbird-server/`](../docs/examples/netbird-server/).
- `--1password` - Deprecated alias for `--secret-provider 1password`
- `--features` - Comma-separated optional non-provider features: `tui` (proxy console mode; prefer `--proxy tui`)
- `--name` - Project name for Docker Compose (default: derived from directory name)
- `--path` - Project directory (default: current directory)

Selected stacks are installed via [mise](https://mise.jdx.dev/) in the container's Dockerfile. Versions default
to LTS where available (e.g. Node.js LTS, Java LTS). Selecting `scala` automatically includes `java`. Stacks
with a VS Code extension (e.g. `rust-analyzer`, `metals`) have it added to `devcontainer.json`.

Fully non-interactive examples:
```bash
sandcat init --agent claude --ide vscode --stacks "python,node" --name myproject --path /some/dir

# Cursor CLI provider
sandcat init --agent cursor --ide vscode --stacks "python,node" --name myproject --path /some/dir

# With 1Password integration
sandcat init --agent claude --ide vscode --secret-provider 1password --name myproject

# With Proton Pass integration
sandcat init --agent claude --ide vscode --secret-provider protonpass --name myproject

# With NetBird dynamic WireGuard
sandcat init --agent claude --ide vscode --netbird --name myproject

# With NetBird + capability sidecar (reachability == capability)
sandcat init --agent cursor --ide vscode --netbird --capability --name myproject

# Point at an existing self-hosted management server
sandcat init --agent cursor --ide vscode --netbird \
  --netbird-management-url https://netbird.example.com --name myproject
```

#### Proton Pass setup (scoped Personal Access Token)

Proton Pass uses a **Personal Access Token (PAT)** — not your account password. A PAT starts with zero access and you explicitly grant it read-only access to only the vaults or items sandcat needs. This means the mitmproxy container can only see the secrets you chose, nothing else.

```bash
# 1. Create a PAT with zero access (valid 3 months)
pass-cli pat create --name "sandcat" --expiration 3m
# → prints: PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_xxxx...xxxx::TOKENKEY

# 2. Grant read-only access to ONLY the vault(s) this project needs
pass-cli pat access grant --pat-name "sandcat" --vault-name "MyVault" --role viewer
# Or restrict to a single item:
# pass-cli pat access grant --pat-name "sandcat" --vault-name "MyVault" --item-title "Anthropic Key" --role viewer

# 3. Add the pst_... token to ~/.config/sandcat/settings.json
```

```json
{
  "proton_pass_token": "pst_xxxx...xxxx::TOKENKEY",
  "secrets": {
    "GITHUB_TOKEN": {
      "pass": "pass://MyVault/GitHub Token/credential",
      "hosts": ["github.com", "*.github.com", "*.githubusercontent.com"]
    }
  }
}
```

At startup, sandcat logs into `pass-cli` using the PAT and verifies the session is scoped (not a full account credential). If a full account credential is detected, mitmproxy refuses to start with a security error.

> **Note:** This check is fail-closed and applies only when at least one `pass://` secret is configured. A misconfigured or non-scoped Proton Pass token prevents the mitmproxy proxy from starting **at all** — so `op://` secrets, plain-value secrets, and network policy will also be unavailable until the token is fixed. If the proxy fails to come up after adding a `pass://` secret, check the mitmproxy logs for the PAT security error rather than assuming a broader outage.

##### Building the `mitmproxy-pass` image locally

The published image (`ghcr.io/virtuslab/sandcat-mitmproxy-pass`) is built in CI, but you can build it locally. The pinned `pass-cli` version and per-arch checksums live in a single source of truth, [`images/mitmproxy-pass/pass-cli.env`](../images/mitmproxy-pass/pass-cli.env), and must be passed in as build args (the Dockerfile has no defaults on purpose):

```bash
set -a; . images/mitmproxy-pass/pass-cli.env; set +a
docker build \
  --build-arg PASS_CLI_VERSION \
  --build-arg PASS_CLI_SHA256_X86_64 \
  --build-arg PASS_CLI_SHA256_AARCH64 \
  -t sandcat-mitmproxy-pass:local \
  images/mitmproxy-pass
```

PAT detection relies on the wording of `pass-cli info` output. Because the binary is pinned by version **and** sha256, that output cannot change without a deliberate bump. A contract test (`TestPassCliPatContract`) locks the detection regex against golden samples tagged with `PASS_CLI_VERSION`. When you bump `pass-cli.env`, you must also re-capture those samples — see [`cli/test/mitmproxy/fixtures/pass-cli/README.md`](test/mitmproxy/fixtures/pass-cli/README.md) — or CI will fail.

Note: Cursor agent support currently uses compatibility defaults for auth/network
settings while provider-specific hardening is being expanded.
Use `CURSOR_API_KEY` for Cursor authentication.
Sandcat always bootstraps Cursor CLI with `.network.useHttp1ForAgent = true`.

#### `sandcat init devcontainer`

Sets up a devcontainer configuration for an agent. Copies devcontainer template files and customizes the
compose-all.yml.

Options:
- `--settings-file` - Path to the settings file (relative to project directory)
- `--project-path` - Path to the project directory
- `--agent` - The agent name (e.g., `claude`, `cursor`)
- `--ide` - The IDE name (e.g., `vscode`, `jetbrains`, `none`) (optional)
- `--stacks` - Space-separated development stacks (e.g., `"python java"`) (optional)
- `--name` - Project name for Docker Compose (default: `{dir}-sandbox`)
- `--secret-provider` - `none`, `1password`, or `protonpass` (optional; default `none`)
- `--1password` - Deprecated alias for `--secret-provider 1password`

#### `sandcat init settings`

Creates a network settings file for the proxy.

Arguments:
- First argument: Path to the settings file

### `sandcat destroy`

Removes all sandcat configuration and containers from a project. Stops running containers, removes volumes, and
deletes configuration directories.

### `sandcat version`

Displays the current version of sandcat.

### `sandcat compose`

Runs docker compose commands with the correct compose file automatically detected. Pass any docker compose arguments
(e.g., `sandcat compose up -d` or `sandcat compose logs`).

### `sandcat edit compose`

Opens the Docker Compose file in your editor. If you save changes and containers are running, it will restart containers by default to apply the changes.

Options:
- `--no-restart` — Do not automatically restart containers after changes. When set (or when `SANDCAT_NO_RESTART=true`), a warning is shown instead with instructions to run `sandcat compose up -d` manually.

### `sandcat edit project-settings`

Opens the project network settings file (`.sandcat/settings.json`) in your editor.

### `sandcat edit user-settings`

Opens the user-wide settings file (`~/.config/sandcat/settings.json`) in your editor. This file contains git
identity, API key secrets, and service-specific network rules.

### `sandcat edit dockerfile`

Opens the container Dockerfile (`.devcontainer/Dockerfile.app`) in your editor. Use this to add or change
development stack versions installed via mise.

### `sandcat proxy`

Opens the mitmproxy interface for traffic inspection. Behavior depends on the proxy mode chosen during
`sandcat init`:
- **web** (default): prints the mitmweb URL and password
- **tui**: tails the mitmdump flow log (Ctrl+C to stop)

### `sandcat restart-proxy`

Restarts the mitmproxy and wg-client services to pick up settings changes. Run this after editing any settings
file (project or user) to apply the new configuration.

### `sandcat run`

Runs a command inside the agent container. If no command is specified, opens a shell. Example: `sandcat run` opens a
shell, `sandcat run npm install` runs npm inside the container.

Options:
- `--build` — Rebuild images before running (e.g. after editing `Dockerfile.app`)

## Dynamic networking (NetBird)

When initialized with `--netbird`, sandcat enrolls **mitmproxy** as a NetBird peer.
The NetBird client daemon runs inside the mitmproxy container and manages `wt0` — a
second WireGuard interface for the overlay mesh. Agent traffic always flows:

```
agent → wg0 (wg-client kill switch) → mitmproxy (L7 inspect + secrets) → internet
                                                                        ↘ wt0 (leased mesh)
```

This design eliminates the routing collision that occurred when NetBird ran on `wg-client`
alongside `wg0` (WireGuard-in-WireGuard). wg-client is now a pure tunnel shim with no
NetBird involvement.

The NetBird client binary is pinned by version and per-arch sha256 in
[`templates/devcontainer/sandcat/netbird.env`](templates/devcontainer/sandcat/netbird.env).
`sandcat init --netbird` injects these as compose build args for `Dockerfile.mitmproxy`
automatically. NetBird is downloaded and checksum-verified in a throwaway builder stage,
then copied into a final image built `FROM $BASE_IMAGE`.

`BASE_IMAGE` defaults to `mitmproxy/mitmproxy:latest`. When a secret provider is also
selected, `sandcat init` sets it to that provider's variant
(`ghcr.io/virtuslab/sandcat-mitmproxy-pass` or `-op`), so the proxy ends up with **both**
NetBird and the provider CLI. Combining `--netbird` with `--secret-provider` therefore
keeps `pass://` and `op://` references resolvable.

To build the image manually:

```bash
cd cli/templates/devcontainer/sandcat
set -a; . netbird.env; set +a
docker build -f Dockerfile.mitmproxy \
  --build-arg NETBIRD_VERSION \
  --build-arg NETBIRD_SHA256_AMD64 \
  --build-arg NETBIRD_SHA256_ARM64 \
  --build-arg BASE_IMAGE=ghcr.io/virtuslab/sandcat-mitmproxy-pass:latest \
  -t mitmproxy-netbird-test .
```

### Setup

NetBird uses **two separate credentials**. Both go in `~/.config/sandcat/settings.json`
(created by `sandcat init`; edit with `sandcat edit user-settings`):

| Setting key | Used for | Where to get it |
|-------------|----------|-----------------|
| `netbird_enrollment_key` | Enrolling mitmproxy as a mesh peer (`NB_SETUP_KEY`) | NetBird dashboard → **Setup Keys** |
| `netbird_api_token` | `sandcat netbird` CLI commands on your host | NetBird dashboard → **API Keys** (Personal Access Token) |
| `netbird_management_url` | Host-side management API (`sandcat netbird`, browser) | Empty = cloud; otherwise your server URL |
| `netbird_enrollment_management_url` | mitmproxy enrollment URL (container cannot use `localhost`) | Docker host LAN IP for a local server; see [docs/examples/netbird-server](../docs/examples/netbird-server/) |

**Before `sandcat netbird status` works**, you must complete steps 1–4 below.
Container enrollment (`netbird_enrollment_key`) is separate from host CLI control
(`netbird_api_token`) — you need the API token even if the devcontainer is already running.

1. Create a NetBird account at <https://app.netbird.io> or self-host the server.
2. In the dashboard, create a **Setup Key** (for peer enrollment).
3. In the dashboard, create an **API Key** / personal access token (for `sandcat netbird` commands).
4. Add both values to user settings:

```json
{
  "netbird_enrollment_key": "your-setup-key-here",
  "netbird_api_token": "your-api-token-here"
}
```

Or edit interactively:

```bash
sandcat edit user-settings
```

`sandcat compose` and `sandcat run` read `netbird_enrollment_key` and export
`NB_SETUP_KEY` automatically when starting containers. `sandcat netbird`
commands read `netbird_api_token` from the same settings layers (project
settings override user settings when non-empty). Environment variables
`NB_SETUP_KEY` and `NB_API_TOKEN` override settings when set.

### Management server

Sandcat configures connection details; it does not create or lifecycle a
NetBird management server.

- **Cloud** — omit `--netbird-management-url` (defaults to `https://api.netbird.io`).
- **Existing self-hosted** — pass `--netbird-management-url <http(s)://url>`.
- **Run a local server yourself** — follow
  [`docs/examples/netbird-server/`](../docs/examples/netbird-server/), then
  point sandcat at it.

```bash
# Cloud
sandcat init --agent claude --ide vscode --netbird --name myproject

# Existing self-hosted management server
sandcat init --agent claude --ide vscode --netbird \
  --netbird-management-url https://netbird.example.com --name myproject
```

Interactive `sandcat init --netbird` (when other options are also prompted)
offers cloud vs “I have a server running”.

### Local self-hosted

For development on your machine without a public domain, run the compose
stack in [`docs/examples/netbird-server/`](../docs/examples/netbird-server/)
yourself (`docker compose --env-file netbird-server.env up -d`). Then:

1. Bootstrap admin: `POST http://localhost:33073/api/setup` (see the example README).
2. Open **http://localhost:8080** and sign in.
3. Create setup key + API token in the dashboard.
4. Set credentials in `~/.config/sandcat/settings.json` (or project
   `.sandcat/settings.local.json`):

```json
{
  "netbird_management_url": "http://localhost:33073",
  "netbird_enrollment_management_url": "http://<docker-host-ip>:33073",
  "netbird_enrollment_key": "<setup-key>",
  "netbird_api_token": "<api-token>"
}
```

**Finding the Docker host IP** (mitmproxy cannot use `localhost`):

```bash
# Colima
colima status -j | jq -r '.network.gateway_address'

# Docker Desktop (macOS) — often 192.168.65.2; verify with:
docker run --rm alpine getent ahostsv4 host.docker.internal | awk '{print $1; exit}'
```

Set `server.exposedAddress` in the example `config.yaml` to the same host IP,
recreate the netbird-server container, then recreate mitmproxy:

```bash
sandcat init --netbird --netbird-management-url http://localhost:33073 ...
sandcat run --force-recreate mitmproxy
```

### Remote self-hosted (NetBird quickstart)

For a VM with a public domain, use the
[official quickstart](https://docs.netbird.io/selfhosted/selfhosted-quickstart#installation-script):

```bash
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh | bash
```

The script generates `docker-compose.yml`, `config.yaml`, and `dashboard.env`
with embedded IdP support. Follow the prompts (Traefik `[0]` is the default).

**First-time onboarding** (from the [quickstart guide](https://docs.netbird.io/selfhosted/selfhosted-quickstart#installation-script)):

1. Open `https://<your-domain>` in a browser.
2. You are redirected to `/setup` while no users exist.
3. Create the admin account (email, name, password).
4. In the dashboard, create a **Setup Key** and an **API Key** (PAT).

For scripted bootstrap instead of the dashboard setup page, see
[Automated setup with a Personal Access Token](https://docs.netbird.io/selfhosted/automated-setup).

**Wire sandcat** after the server is running:

```json
"netbird_management_url": "https://netbird.example.com",
"netbird_enrollment_key": "<setup-key>",
"netbird_api_token": "<api-token>"
```

Re-run `sandcat init --netbird --netbird-management-url https://netbird.example.com ...`
or edit `~/.config/sandcat/settings.json` directly, then `sandcat run`.

### Runtime control

```bash
# List current peers
sandcat netbird status

# Remove a peer (mitmproxy drops the route within one daemon poll interval)
sandcat netbird peer remove --peer-id <peer-id>

# Add a network route served by a peer
sandcat netbird route add --network 10.8.0.0/24 --peer-id <peer-id>

# Remove a route
sandcat netbird route remove --route-id <route-id>
```

## Capability sidecar (Phase 3b)

When initialized with `--netbird --capability`, sandcat deploys a trusted
`capability-runtime` compose sidecar alongside the agent. The sidecar owns
`CapabilityRuntime` state, NetBird revocation credentials, and the route watcher.
The agent container talks to the runtime only through a thin MCP bridge over a
read-only Unix socket — it never receives `NB_API_TOKEN` or direct NetBird access.

```
Agent (Cursor/Claude)  ──stdio MCP──►  capability-mcp-bridge  ──►  agent.sock
Operator (host)        ──compose exec──►  admin.sock
Sidecar                ──RestNetBirdClient──►  NetBird management API
```

### Setup

Requires NetBird (`--netbird`) and both credentials in user settings (see
[Dynamic networking](#dynamic-networking-netbird)). The sidecar reads
`netbird_api_token` and `netbird_management_url` from mounted `settings.json`;
the agent container does not receive these values.

```bash
sandcat init --agent cursor --ide vscode --netbird --capability --name myproject
sandcat compose up -d
```

### Cursor MCP config

Add to `.cursor/mcp.json` in the devcontainer (the bridge is installed at
`/usr/local/bin/capability-mcp-bridge`):

```json
{
  "mcpServers": {
    "sandcat-capability": {
      "command": "capability-mcp-bridge",
      "args": []
    }
  }
}
```

MCP meta-tools: `capability_check`, `capability_lease`, `capability_discover`.
Workload tools remain on their own MCP servers and appear in the bundle only
when leased or visible.

### Operator commands

`sandcat capability` runs inside the `capability-runtime` container via
`docker compose exec` — no host-published ports.

```bash
# Show current capability bundle
sandcat capability check --context '{}'

# Lease a network capability (triggers NetBird peer/route via sidecar)
sandcat capability lease --ref cap-reach-api --justification "need API access"

# Revoke (operator-only; disables NetBird route by default, keeps peer)
sandcat capability revoke --ref cap-reach-api --reason policy

# Foreground route-watcher poll loop (debugging)
sandcat capability watch
```

### Security boundary

| Path | Socket | Who | Can revoke? |
|------|--------|-----|-------------|
| Agent MCP bridge | `agent.sock` (ro mount) | Agent in container | No |
| `sandcat capability` | `admin.sock` | Operator on host | Yes |

- `admin.sock` is not mounted in the agent service
- Agent RPC surface rejects `capability.revoke` and unknown methods
- `SANDCAT_AGENT_ID` is fixed per devcontainer and injected by the bridge;
  agent-supplied `agent_id` parameters are ignored
- Catalog is loaded at sidecar startup from config — not registerable over RPC

### Phase 3c grant/revoke flow

When the sidecar loads a network capability from the catalog, each entry may include a `sync_mode` that controls how NetBird physical state is synchronized on lease and revoke:

| `sync_mode` | On lease (`enable_binding`) | On revoke (`disable_binding`) |
|-------------|----------------------------|-------------------------------|
| `route_enable` (default) | Enable or create NetBird route for the binding | Disable route; peer stays enrolled |
| `peer_remove` | No-op (peer already enrolled) | Delete peer (Phase 3 break-glass) |
| `acl_policy` | Stub — future ACL/group sync | Stub |

```bash
# Lease triggers enable_binding → route visible on wt0
sandcat capability lease --ref cap-reach-api --justification "need API access"
sandcat netbird status   # route enabled

# Revoke triggers disable_binding → route gone, peer remains
sandcat capability revoke --ref cap-reach-api --reason done
sandcat netbird status   # route disabled; peer still listed
```

Grant failure rolls back the lease (fail closed). Only the operator admin socket can revoke; agents cannot trigger `enable_binding` or `disable_binding`.

#### Capability catalog schema (network entries)

Network capabilities in `capability-catalog.json` (mounted as `CAPABILITY_CATALOG_JSON` at sidecar startup):

```json
{
  "capabilities": [
    {
      "name": "reach_api",
      "ref": "cap-reach-api",
      "type": "network",
      "peer_id": "<netbird-peer-id>",
      "network": "10.8.0.0/24",
      "route_id": "<netbird-route-id>",
      "sync_mode": "route_enable"
    }
  ]
}
```

- `peer_id`, `network` — required NetBird identifiers for the binding. `peer_id` refers to the **mitmproxy** NetBird peer (hostname `{project}-proxy`, e.g. `myproject-proxy` when initialized with `--name myproject`).
- `route_id` — optional; if omitted, `enable_binding` creates a route via the NetBird API and stores the returned id
- `sync_mode` — optional; defaults to `route_enable`. Use `peer_remove` only when revoke must delete the peer (legacy Phase 3 behavior)

Tool capabilities (`type: "tool"`) do not use `sync_mode` or binding fields.

#### Catalog IDs for live smoke

Replace placeholders in `capability-catalog.json` before leasing `reach_api`:

1. Find the mitmproxy peer ID (the stack's sole mesh participant):
   ```bash
   docker compose exec mitmproxy netbird status --json | jq -r '.id'
   ```
   Or look for hostname `{project}-proxy` (e.g. `myproject-proxy`) in the NetBird dashboard.
2. `sandcat netbird route list` (or NetBird dashboard) — copy route ID if pre-provisioned
3. Re-init or edit `.devcontainer/sandcat/capability-catalog.json`
4. Restart capability-runtime: `docker compose restart capability-runtime`

**Migration note:** If you previously used a `wg-client` peer as `peer_id` in your catalog, replace it with the mitmproxy peer ID. Remove the old `wg-client` peer from the NetBird dashboard.

## Optional mesh gateway (proxy-peer)

Sandcat does not create a proxy-peer container. To run a small NetBird-enrolled
HTTP gateway beside the project and lease it via capability-runtime `dns_label`,
follow [`docs/examples/proxy-peer/`](../docs/examples/proxy-peer/). Init with
`--netbird --capability` still enrolls the mitmproxy peer
(`netbird_peer_name_proxy`, default `{project}-proxy`); add the gateway catalog
entry and Layer 1 allow rule by hand.

### Usage-metered quota (L7 record)

When `--capability` is enabled, mitmproxy can decrement network lease quota from
post-hoc flow records. Set `CAPABILITY_L7_RECORD=1` in the mitmproxy service
environment (compose passes the variable through when capability is enabled; set
the value in your shell or `.env` before `sandcat compose up`). Each successful
HTTP response to a mesh or Layer-1-allowed host emits `capability.l7.record` on
the admin socket; quota exhaustion triggers the same auto-revoke path as tool
quota.

## Directory Structure

Each module is contained in its own directory under `cli/libexec/`.
Modules can be decomposed into multiple commands, the default command being the module's name
(e.g.`cli/libexec/init/init`)
The entrypoint extends the `PATH` with the current module's libexec directory, so that it can call other commands in the
same module by their name.

```
cli/
├── bin/
│   └── sandcat           # Main CLI entry point
├── lib/                   # Shared library functions
├── libexec/               # Module implementations
│   ├── destroy/           #    Each module can contain multiple commands
│   ├── init/
│   └── version/
├── support/               # BATS and it's extensions
├── templates/             # Configuration templates
└── test/             	   # BATS tests
```

## Environment Variables

### Internal (set by the CLI)

- `SCT_ROOT` - Root directory of sandcat CLI
- `SCT_LIBDIR` - Library directory (default: `$SCT_ROOT/lib`)
- `SCT_LIBEXECDIR` - Directory for module implementations (default: `$SCT_ROOT/libexec`)
- `SCT_TEMPLATEDIR` - Directory for templates (default: `$SCT_ROOT/templates`)

### Configuration (set before running `sandcat init`)

These override defaults during compose file generation. Optional volumes default to `false` (commented out),
except provider config mounts, which default to `true` for the selected agent.

- `SANDCAT_MOUNT_CLAUDE_CONFIG` - `true` to mount host `~/.claude` config (Claude agent only)
- `SANDCAT_MOUNT_CURSOR_CONFIG` - `true` to mount host `~/.cursor` config (Cursor agent only)
- `SANDCAT_MOUNT_GIT_READONLY` - `true` to mount `.git/` directory as read-only
- `SANDCAT_MOUNT_IDEA_READONLY` - `true` to mount `.idea/` directory as read-only (JetBrains)

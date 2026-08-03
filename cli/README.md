# Sandcat CLI

Command-line tool for managing sandcat configurations and Docker Compose setups.

Requires `docker` (and `docker compose`) and [`yq`](https://github.com/mikefarah/yq).

## Modules and Commands

### `sandcat init`

Initializes sandcat for a project. Prompts for any options not provided via flags, then sets up the necessary
configuration files and network settings. Optional volume mounts (agent config, .git, .idea) are included as
commented-out entries in the generated compose file (agent config defaults to active for the selected agent).

Options:
- `--agent` - Agent type: `claude`, `cursor`, `codex` (skips prompt)
- `--ide` - IDE for devcontainer mode: `vscode`, `jetbrains`, `none` (skips prompt)
- `--stacks` - Comma-separated development stacks to install: `node`, `python`, `java`, `rust`, `go`, `scala`, `ruby`, `dotnet`, `zig` (skips prompt)
- `--proxy` - Proxy UI mode: `web` (default, mitmweb browser UI) or `tui` (mitmproxy console, use with `sandcat proxy` to attach)
- `--secret-provider` / `--sp` - Secret backend: `none` (default), `1password`, `protonpass` (skips prompt when set)
- `--1password` - Deprecated alias for `--secret-provider 1password`
- `--features` - Comma-separated optional non-provider features: `tui` (proxy console mode; prefer `--proxy tui`), `no-gitignore` (skip appending the `# Sandcat` block to the project's `.gitignore`; equivalent to `SANDCAT_GITIGNORE=false`), `no-rtk` (skip RTK installation; equivalent to `SANDCAT_RTK=false`)
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

Note: Cursor agent support uses placeholder-based API key substitution and
Sandcat-managed CLI settings (`cursor.cli` in settings — permissions, model,
network flags). Put the API key in `secrets.CURSOR_API_KEY`, not in
`cursor.cli`. See the main README Cursor section for details.

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

### `sandcat cache`

Manages the host-scoped shared dependency-cache volumes (`sandcat-cache-*`)
that back the shared-cache feature (see main README §*Shared dependency
caches*). Bare `sandcat cache` is a shorthand for `sandcat cache list`.

Subcommands:

- `list` — print a table with volume name, size, file count, and any
  running containers currently mounting it, plus a total-size row.
- `size` — one-liner total size across every shared-cache volume on the
  host.
- `rm <volume>|--all [--force] [--yes]` — remove one or all shared-cache
  volumes. Refuses by default when a running container still holds a
  volume open; `--force` bypasses the check (Docker itself will still
  refuse a truly locked volume). `--yes` skips the interactive
  confirmation, for scripting.

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

Per-folder mounts are **not** separate init flags — tune individual paths by
editing `.devcontainer/compose-all.yml` after init. See the main
[README section on customizing optional volume mounts](../README.md#customizing-optional-volume-mounts).

- `SANDCAT_MOUNT_CLAUDE_CONFIG` - `true` to mount host `~/.claude` config (Claude agent only)
- `SANDCAT_MOUNT_CURSOR_CONFIG` - `true` to mount host `~/.cursor` customization
  (read-only) and workspace-scoped runtime state (read-write:
  `projects/<workspace-id>/` only) into the agent container (Cursor agent
  only). `chats/`, `plugins/`, and `subagents/` stay in agent-home. Sandcat
  CLI settings (`cursor.cli` — not API keys) are merged into agent-home
  `cli-config.json` at container startup — not host-mounted. API keys belong
  in `secrets.CURSOR_API_KEY` and are substituted by mitmproxy.
- `SANDCAT_MOUNT_GIT_READONLY` - `true` to mount `.git/` directory as read-only
- `SANDCAT_MOUNT_IDEA_READONLY` - `true` to mount `.idea/` directory as read-only (JetBrains)

# Agent Sandbox CLI

Command-line tool for managing sandcat configurations and Docker Compose setups.

Requires `docker` (and `docker compose`) and [`yq`](https://github.com/mikefarah/yq).

## Modules and Commands

### `agentbox init`

Initializes sandcat for a project. Prompts for any options not provided via flags, then sets up the necessary
configuration files and network policy. Optional volume mounts (Claude config, shell customizations, dotfiles, .git,
.idea, .vscode) are included as commented-out entries in the generated compose file.

Options:
- `--agent` - Agent type: `claude`, `copilot` (skips prompt)
- `--ide` - IDE for devcontainer mode: `vscode`, `jetbrains`, `none` (skips prompt)
- `--name` - Project name for Docker Compose (default: derived from directory name)
- `--path` - Project directory (default: current directory)

Fully non-interactive example:
```bash
agentbox init --agent claude --ide vscode --name myproject --path /some/dir
```

#### `agentbox init devcontainer`

Sets up a devcontainer configuration for an agent. Copies devcontainer template files and customizes the
compose-all.yml.

Options:
- `--policy-file` - Path to the policy file (relative to project directory)
- `--project-path` - Path to the project directory
- `--agent` - The agent name (e.g., `claude`)
- `--ide` - The IDE name (e.g., `vscode`, `jetbrains`, `none`) (optional)
- `--name` - Project name for Docker Compose (default: `{dir}-sandbox-devcontainer`)

#### `agentbox init policy`

Creates a network policy file for the proxy.

Arguments:
- First argument: Path to the policy file
- Remaining arguments: Service names to include (e.g., `claude`, `copilot`, `vscode`, `jetbrains`)

### `agentbox destroy`

Removes all sandcat configuration and containers from a project. Stops running containers, removes volumes, and
deletes configuration directories.

### `agentbox version`

Displays the current version of sandcat.

### `agentbox compose`

Runs docker compose commands with the correct compose file automatically detected. Pass any docker compose arguments
(e.g., `agentbox compose up -d` or `agentbox compose logs`).

### `agentbox edit compose`

Opens the Docker Compose file in your editor. If you save changes and containers are running, it will restart containers by default to apply the changes.

Options:
- `--no-restart` — Do not automatically restart containers after changes. When set (or when `SANDCAT_NO_RESTART=true`), a warning is shown instead with instructions to run `agentbox up -d` manually.

### `agentbox edit policy`

Opens the network policy file in your editor. If you save changes, the proxy service will automatically restart to apply
the new policy.

### `agentbox run`

Runs a command inside the agent container. If no command is specified, opens a shell. Example: `agentbox run` opens a
shell, `agentbox run npm install` runs npm inside the container.

## Directory Structure

Each module is contained in its own directory under `cli/libexec/`.
Modules can be decomposed into multiple commands, the default command being the module's name
(e.g.`cli/libexec/init/init`)
The entrypoint extends the `PATH` with the current module's libexec directory, so that it can call other commands in the
same module by their name.

```
cli/
├── bin/
│   └── agentbox           # Main CLI entry point
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

### Configuration (set before running `agentbox init`)

These override defaults during compose file generation. Optional volumes default to `false` (commented out).

- `SANDCAT_MOUNT_CLAUDE_CONFIG` - `true` to mount host `~/.claude` config (Claude agent only)
- `SANDCAT_MOUNT_GIT_READONLY` - `true` to mount `.git/` directory as read-only
- `SANDCAT_MOUNT_IDEA_READONLY` - `true` to mount `.idea/` directory as read-only (JetBrains)
- `SANDCAT_MOUNT_VSCODE_READONLY` - `true` to mount `.vscode/` directory as read-only (VS Code)

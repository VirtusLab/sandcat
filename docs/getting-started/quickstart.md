# Quick start

Sandcat is a Docker & [dev container](https://containers.dev) setup for
securely running AI agents. The environment is sandboxed, with controlled
network access and transparent secret substitution: all container traffic is
routed through a transparent [mitmproxy](https://mitmproxy.org/) via
WireGuard, an allow/deny policy controls which requests go through, and
secrets are injected at the proxy level so the container never sees real
values.

## 1. Install the sandcat CLI

Requires `docker` (with `docker compose`) and
[`yq`](https://github.com/mikefarah/yq) (Mike Farah's Go variant).

```bash
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh
```

This installs the CLI to `~/.local/share/sandcat/` with a launcher symlink at
`~/.local/bin/sandcat` — make sure `~/.local/bin` is on your `PATH`. For all
install options (Docker image, git clone, uninstall), see
[Installation](../installation.md).

## 2. Initialize the sandbox for your project

From (or pointing at) your project directory:

```bash
sandcat init
```

This prompts you to select the agent type, IDE (for devcontainer mode), and
development stacks to install, then copies the devcontainer templates into
`.devcontainer/`, creates the network policy in `.sandcat/settings.json`, and
seeds user-level settings (API-key placeholders, git identity) in
`~/.config/sandcat/settings.json`. Pass flags to skip the prompts:

```bash
sandcat init --agent claude --ide vscode --stacks "python,node"

# With optional features (proxy TUI, 1Password integration)
sandcat init --secret-provider 1password --agent claude --ide vscode
```

Available agents — see the **Agents** chapter for per-agent setup:
[`claude`](../agents/claude.md) (Claude Code),
[`cursor`](../agents/cursor.md) (Cursor CLI),
[`codex`](../agents/codex.md) (OpenAI Codex CLI),
[`copilot`](../agents/copilot.md) (GitHub Copilot CLI).

Available stacks: `node`, `python`, `java`, `rust`, `go`, `scala`, `ruby`,
`dotnet`, `zig`. Versions default to LTS where available; selecting `scala`
automatically includes `java`, and stacks install the matching IDE
extension/plugin. Version overrides and extra tools go through
[devbox packages](../configuration/stacks.md); optional bind-mounts and
shared caches are covered under
[Volume mounts](../configuration/volume-mounts.md) and
[Shared dependency caches](../configuration/caches.md).

## 3. Add your API keys

Edit `~/.config/sandcat/settings.json` and fill in the seeded secrets — for
example `ANTHROPIC_API_KEY` (Claude Code) and `GITHUB_TOKEN` (git push, gh
CLI). With a secret provider, use `op://` / `pass://` references instead of
literal values.

## 4. Start the sandbox

**CLI mode:**

```bash
# Open a shell in the agent container
sandcat run

# Rebuild images first (after editing Dockerfile.app or scripts)
sandcat run --build

# Start your agent cli (e.g. claude). Because you're in a sandbox, you can use yolo mode!
# (an alias for --dangerously-skip-permissions)
claude-yolo
```

**IDE mode:** reopen the project in [VS Code](../ide/vscode.md) or
[JetBrains](../ide/jetbrains.md) as a dev container. The first start builds
the agent image and brings up the proxy stack; subsequent starts are fast.

**Attaching to a running container:**

If the sandbox is already running (e.g. started by VS Code's devcontainer
integration or another terminal), use `attach` to open an additional shell in
it without starting a new container:

```bash
sandcat attach           # opens bash --login
sandcat attach <cmd>     # runs <cmd> directly, e.g. sandcat attach zsh
```

Unlike `sandcat run`, this connects to an existing container rather than
starting a fresh one, and works reliably even when multiple sandboxes run in
parallel.

Useful commands once running:

```bash
sandcat proxy        # mitmweb UI (traffic inspection) or proxy log
sandcat restart      # apply edited settings to a live sandbox
sandcat compose ...  # any docker compose command, correct file auto-detected
sandcat destroy      # tear everything down (containers, volumes, config)
```

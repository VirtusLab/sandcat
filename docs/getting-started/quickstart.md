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
`~/.local/bin/sandcat` — make sure `~/.local/bin` is on your `PATH`. A local
git clone works too: run `cli/bin/sandcat` from the checkout.

## 2. Initialize the sandbox for your project

From (or pointing at) your project directory:

```bash
sandcat init --agent claude --ide vscode --stacks "python,node" --name myproject
```

`init` copies the devcontainer templates into `.devcontainer/`, creates the
network policy in `.sandcat/settings.json`, and seeds user-level settings
(API-key placeholders, git identity) in `~/.config/sandcat/settings.json`.
Any flag you omit is prompted for interactively.

Commonly used flags:

- `--agent` — `claude`, `cursor`, `codex`, or `copilot`
- `--ide` — `vscode`, `jetbrains`, or `none`
- `--stacks` — comma-separated toolchains to install (`python`, `node`,
  `java`, `rust`, `go`, `scala`, `ruby`, `dotnet`, `zig`)
- `--secret-provider` — `none` (default), `1password`, or `protonpass`

## 3. Add your API keys

Edit `~/.config/sandcat/settings.json` and fill in the seeded secrets — for
example `ANTHROPIC_API_KEY` (Claude Code) and `GITHUB_TOKEN` (git push, gh
CLI). With a secret provider, use `op://` / `pass://` references instead of
literal values.

## 4. Run

```bash
sandcat run          # opens a shell inside the agent container
```

or reopen the project in VS Code / JetBrains as a dev container. The first
start builds the agent image and brings up the proxy stack; subsequent starts
are fast.

Useful commands once running:

```bash
sandcat proxy        # mitmweb UI (traffic inspection) or proxy log
sandcat restart      # apply edited settings to a live sandbox
sandcat compose ...  # any docker compose command, correct file auto-detected
sandcat destroy      # tear everything down (containers, volumes, config)
```

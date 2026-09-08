# Sandcat

Sandcat is a Docker & [dev container](https://containers.dev) setup for securely
running AI agents (Claude Code, Cursor CLI, Codex CLI, GitHub Copilot CLI). The
environment is sandboxed, with controlled network access and transparent secret
substitution. All of this is done while retaining the convenience of working in
an IDE like VS Code.

All container traffic is routed through a transparent
[mitmproxy](https://mitmproxy.org/) via WireGuard, capturing HTTP/S, DNS, and
all other TCP/UDP traffic without per-tool proxy configuration. A
straightforward allow/deny list-based engine controls which network requests go
through, and a secret substitution system injects credentials at the proxy level
so the container never sees real values.

> Sandcat is part of [Visdom](https://virtuslab.com/services/visdom),
> VirtusLab's AI-native SDLC platform.

## Documentation

**Full documentation: [sandcat.virtuslab.com](https://sandcat.virtuslab.com)**
covering the entire Sandcat feature set.

## Quick start

Requires `docker` (with `docker compose`) and [`yq`](https://github.com/mikefarah/yq).

```bash
# 1. Install the CLI
curl -fsSL https://raw.githubusercontent.com/VirtusLab/sandcat/master/install.sh | sh

# 2. Initialize the sandbox in your project
sandcat init --agent claude --ide vscode --stacks "python,node" --name myproject

# 3. Add API keys to ~/.config/sandcat/settings.json, then run
sandcat run          # or reopen the project as a dev container
```

See the docs for the full walkthrough, all `init` options, and the settings
reference.

## Repository layout

* `cli/` — the sandcat CLI: a helper script and thin wrapper around
  docker-compose that initializes the sandbox for a project and runs compose
  commands with the correct file auto-detected
* `cli/templates/devcontainer/sandcat/` — reusable proxy definitions:
  `Dockerfile.wg-client`, `compose-proxy.yml`, `compose-agent.yml`, and the
  `scripts/` that perform network filtering & secret substitution
* `cli/templates/devcontainer/` — template application and dev container
  configuration (`Dockerfile.app`, `compose-all.yml`, `devcontainer.json`),
  fine-tuned per project and development stack
* `images/` — sources of the published mitmproxy images (1Password and
  Proton Pass variants)
* `docs/` — the documentation site sources (Sphinx + MyST)

Sandcat can be used as a devcontainer setup, or standalone, providing a shell
for secure development.

## Development

See the [Development](docs/project/development.md) page for how the CLI tests
(bats), the mitmproxy addon tests (pytest), and shellcheck are run.

## Commercial Support

We offer commercial services around AI-assisted software development. [Contact
us](https://virtuslab.com) to learn more about our offer!

## Copyright

Copyright (C) 2026 VirtusLab [https://virtuslab.com](https://virtuslab.com).

# Sandcat: sandbox for securely running AI agents in "dangerous" mode

Sandcat is a Docker & [dev container](https://containers.dev) setup for
securely running AI agents ([Claude Code](agents/claude.md),
[Cursor CLI](agents/cursor.md), [Codex CLI](agents/codex.md),
[GitHub Copilot CLI](agents/copilot.md)). The environment is sandboxed, with controlled network access
and transparent secret substitution — while retaining the convenience of
working in an IDE — both [VS Code](ide/vscode.md) and
[JetBrains](ide/jetbrains.md) are supported.

All container traffic is routed through a transparent
[mitmproxy](https://mitmproxy.org/) via WireGuard, capturing HTTP/S, DNS, and
all other TCP/UDP traffic without per-tool proxy configuration. A
straightforward allow/deny-list engine controls which network requests go
through, and a secret substitution system injects credentials at the proxy
level so the container never sees real values.

Source code: [github.com/VirtusLab/sandcat](https://github.com/VirtusLab/sandcat).

```{note}
Sandcat is part of [Visdom](https://virtuslab.com/services/visdom),
VirtusLab's AI-native SDLC platform.
```

```{eval-rst}
.. toctree::
   :maxdepth: 2
   :caption: Getting started

   getting-started/quickstart

.. toctree::
   :maxdepth: 2
   :caption: Agents

   agents/claude
   agents/cursor
   agents/codex
   agents/copilot
   agents/rtk

.. toctree::
   :maxdepth: 2
   :caption: IDE integration

   ide/vscode
   ide/jetbrains

.. toctree::
   :maxdepth: 1
   :caption: Installation

   installation

.. toctree::
   :maxdepth: 2
   :caption: Configuration

   configuration/settings
   configuration/applying-changes
   configuration/network-rules
   configuration/dns
   configuration/secrets
   configuration/generated-files
   configuration/stacks
   configuration/volume-mounts
   configuration/caches
   configuration/gitignore
   configuration/docker

.. toctree::
   :maxdepth: 2
   :caption: Architecture

   architecture/overview

.. toctree::
   :maxdepth: 2
   :caption: Reference

   reference/cli
   reference/notes

.. toctree::
   :maxdepth: 2
   :caption: Operations

   operations/testing-proxy
   operations/debugging
   operations/unit-tests

.. toctree::
   :maxdepth: 2
   :caption: Project

   project/inspiration
   project/development
```

## Commercial Support

We offer commercial services around AI-assisted software development. [Contact
us](https://virtuslab.com) to learn more about our offer!
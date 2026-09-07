# sandcat: a sandbox for securely running AI agents

Sandcat is a Docker & [dev container](https://containers.dev) setup for
securely running AI agents (Claude Code, Cursor CLI, Codex CLI, GitHub
Copilot CLI). The environment is sandboxed, with controlled network access
and transparent secret substitution — while retaining the convenience of
working in an IDE like VS Code or JetBrains.

All container traffic is routed through a transparent
[mitmproxy](https://mitmproxy.org/) via WireGuard, capturing HTTP/S, DNS, and
all other TCP/UDP traffic without per-tool proxy configuration. A
straightforward allow/deny-list engine controls which network requests go
through, and a secret substitution system injects credentials at the proxy
level so the container never sees real values.

Source code: [github.com/VirtusLab/sandcat](https://github.com/VirtusLab/sandcat).
Sandcat is part of [Visdom](https://virtuslab.com/services/visdom),
VirtusLab's AI-driven software delivery infrastructure.

```{note}
This site is being migrated from the repository README section by section.
Anything not yet covered here lives in the
[README](https://github.com/VirtusLab/sandcat#readme).
```

```{eval-rst}
.. toctree::
   :maxdepth: 2
   :caption: Getting started

   getting-started/quickstart

.. toctree::
   :maxdepth: 2
   :caption: Configuration

   configuration/network-rules
   configuration/dns

.. toctree::
   :maxdepth: 2
   :caption: Architecture

   architecture/overview
```

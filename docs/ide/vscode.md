# VS Code

Sandcat's primary IDE path: the generated `.devcontainer/devcontainer.json`
is a standard [dev container](https://containers.dev) definition, so opening
the project in VS Code with the **Dev Containers** extension "just works".

## Opening the sandbox

After `sandcat init --ide vscode …`, open the project folder in VS Code and
choose **Reopen in Container** (or let the automatic prompt do it). VS Code
builds the agent image on first open, brings up the proxy stack via the
compose file referenced from `devcontainer.json`, and attaches to the agent
container as the `vscode` user.

Integrated terminals are interactive shells, so they pick up everything the
sandbox environment provides — the sandcat env vars and secret placeholders
(via `/etc/profile.d` and the `/etc/bash.bashrc` sourcing block) and, with a
Java stack, `JAVA_HOME` / `JAVA_TOOL_OPTIONS` pointing at the
mitmproxy-aware trust store.

## The `customizations.vscode` block

`sandcat init` fills `customizations.vscode` in `devcontainer.json` with:

- **Settings** that are part of the sandbox's security posture — see
  [Hardening the VS Code setup](../security/vscode-hardening.md) for what
  each one does and why (workspace trust, `dev.containers.copyGitConfig`,
  credential-socket cleanup).
- **Extensions**: the selected agent's extension (e.g. `GitHub.copilot` for
  the Copilot agent) and one language extension per selected stack:

  | Stack | Extension |
  |-------|-----------|
  | `python` | `ms-python.python` |
  | `java` | `redhat.java` |
  | `rust` | `rust-lang.rust-analyzer` |
  | `go` | `golang.go` |
  | `scala` | `scalameta.metals` |
  | `ruby` | `shopify.ruby-lsp` |
  | `dotnet` | `ms-dotnettools.csdevkit` |
  | `zig` | `ziglang.vscode-zig` |

  (`node` needs no extension — JavaScript/TypeScript support is built into
  VS Code.)

Extensions run inside the container, so their network traffic goes through
the proxy like everything else. If an extension needs extra hosts, add them
to the [network rules](../configuration/network-rules.md) — the `vscode`
[network preset](../configuration/network-rules.md#network-presets) covers
the marketplace and update endpoints.

## Security notes

The VS Code remote architecture forwards host resources into containers by
default; sandcat's template disables or cleans up the risky parts. Read
[Hardening the VS Code setup](../security/vscode-hardening.md) before
loosening any of those settings.

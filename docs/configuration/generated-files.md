# Customizing the generated files

**`sandcat/compose-agent.yml`** — the constant (non-user-editable) base for the
agent service. `network_mode: "service:wg-client"` routes all traffic through
the WireGuard tunnel. The `mitmproxy-public` volume, mounted read-only at
`/mitmproxy-config/`, gives your container the CA cert, env vars, and secret
placeholders — the private `mitmproxy-config` volume, which also holds the CA
private key and the WireGuard keys, is never mounted into the agent.

**`compose-all.yml`** — holds the user-customizable entries merged over that
constant base. The agent-specific config bind-mounts (for example
`~/.claude/*` or `~/.cursor/*`) forward host customizations — remove any
mount whose source does not exist on your host.

**`Dockerfile.app`** — installs everything the sandbox needs via
[devbox](https://www.jetify.com/devbox), a wrapper over Nix. Stack
toolchains and user tools are merged from `devbox.stack.json` +
`devbox.tools.json` into a single devbox global profile at build time —
see [Stack and tool packages via devbox](stacks.md)
for the two-file model. Some runtimes need extra configuration to trust
the mitmproxy CA — see [TLS and CA certificates](../reference/notes.md#tls-and-ca-certificates).

**`devcontainer.json`** — includes VS Code hardening settings (credential socket
cleanup, workspace trust, disabled local terminal). See [Hardening the VS Code
setup](../ide/vscode.md#security-hardening) for details.

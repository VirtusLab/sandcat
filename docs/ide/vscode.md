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
  [Security hardening](#security-hardening) below for what each one does and
  why (workspace trust, `dev.containers.copyGitConfig`, credential-socket
  cleanup).
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

## Security hardening

Sandcat secures the **network path** out of the container, but VS Code's dev
container integration introduces a separate trust boundary. The VS Code remote
architecture gives container-side extensions access to host resources
(terminals, credentials, clipboard) through the IDE channel, bypassing
network-level controls entirely.

For background on these attack vectors see [Leveraging VS Code Internals to
Escape
Containers](https://blog.theredguild.org/leveraging-vscode-internals-to-escape-containers/).

### What the bundled devcontainer.json already does

The included `devcontainer.json` applies the following mitigations out of the
box:

- **Clears forwarded credential sockets** (`SSH_AUTH_SOCK`, `GPG_AGENT_INFO`,
  `GIT_ASKPASS`) via `remoteEnv` so container code cannot piggyback on host SSH
  keys, GPG signing, or VS Code's git credential helpers. Clearing env vars
  alone only hides the path — the socket file in `/tmp` can still be discovered
  by scanning.
- **Removes credential sockets** via a `postStartCommand` script that deletes
  `vscode-ssh-auth-*.sock` and `vscode-git-*.sock` from `/tmp` after VS Code
  connects. This is a best-effort measure — the socket path patterns could
  change in future VS Code versions.
- **Disables git config copying** (`dev.containers.copyGitConfig: false` in
  `devcontainer.json`) to prevent leaking host credential helpers and signing
  key references into the container. The VS Code Dev Containers extension
  reads this setting from your **host** user settings, not from
  `devcontainer.json`, so for full effect also set it there — either via the
  Command Palette (`Preferences: Open User Settings (JSON)`) or by editing the
  file directly:

    - macOS: `~/Library/Application Support/Code/User/settings.json`
    - Linux: `~/.config/Code/User/settings.json`
    - Windows: `%APPDATA%\Code\User\settings.json`

  As a defense-in-depth fallback, `app-user-init.sh` removes any `.gitconfig`
  that gets copied in anyway.
- **Enables workspace trust** (`security.workspace.trust.enabled: true`) so VS
  Code prompts before applying workspace settings that container code could have
  modified via the bind-mounted project folder.
- **Blocks local terminal creation** (`terminal.integrated.allowLocalTerminal:
  false`) so container extensions cannot call
  `workbench.action.terminal.newLocal` to open a shell on the host, which would
  bypass the WireGuard tunnel entirely. For maximum protection, also set this in
  your **host** user settings (workspace settings could theoretically override
  it).
- **Read-only `.devcontainer` overlay** — `compose-all.yml` mounts the
  `.devcontainer` directory as a separate read-only bind mount on top of the
  writable project mount. This prevents the agent from modifying its own sandbox
  configuration (entrypoint scripts, Dockerfile, compose files,
  devcontainer.json).

### Consequences of hardening

Disabling credential forwarding and git config copying improves isolation but
requires a few adjustments.

**Git identity.** With `dev.containers.copyGitConfig` set to `false`, git inside
the container has no `user.name` or `user.email`. Add them to the `env` section
of your `settings.json`:

```json
"env": {
    "GIT_USER_NAME": "Your Name",
    "GIT_USER_EMAIL": "you@example.com"
}
```

The mitmproxy addon writes `env` entries to the shared env file (alongside
secret placeholders), and `app-user-init.sh` applies
`GIT_USER_NAME`/`GIT_USER_EMAIL` via `git config --global` at container startup.

**HTTPS remotes only.** SSH-based git operations won't work — `SSH_AUTH_SOCK` is
cleared and credential sockets are removed, so no SSH keys are available. The
entrypoint automatically rewrites GitHub SSH URLs to HTTPS via `git config
url.*.insteadOf`, so existing `git@github.com:` remotes work without manual
changes. Sandcat's secret substitution handles GitHub token authentication over
HTTPS transparently.

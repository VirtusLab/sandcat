# Secret substitution

Dev containers never see real secret values. Instead, environment variables
contain deterministic placeholders (`SANDCAT_PLACEHOLDER_<NAME>`), and the
mitmproxy addon replaces them with real values when requests pass through the
proxy.

Inside the container, `echo $ANTHROPIC_API_KEY` prints
`SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY`. When a request containing that
placeholder reaches mitmproxy, it's replaced with the real key — but only if the
destination host matches the `hosts` allowlist.

## Host patterns

The `hosts` field accepts glob patterns via `fnmatch`:

- `"api.anthropic.com"` — exact match
- `"*.anthropic.com"` — any subdomain
- `"*"` — allow all hosts (use with caution)

## Leak detection

If a placeholder appears in a request to a host **not** in the allowlist,
mitmproxy blocks the request with HTTP 403 and logs a warning. This prevents
accidental secret leakage to unintended services.

## 1Password integration

Instead of storing secret values directly in settings files, you can reference
secrets stored in 1Password using `op://` references:

```json
{
  "secrets": {
    "ANTHROPIC_API_KEY": {
      "op": "op://Private/Anthropic API Key/credential",
      "hosts": ["api.anthropic.com"]
    }
  }
}
```

Each secret entry must have either `"value"` (plain text) or `"op"` (1Password
reference), not both. You can mix both styles in the same settings file.

The mitmproxy addon resolves `op://` references at startup using the `op` CLI.
To enable 1Password during project setup, select it from the optional features
prompt, or pass the flag:

```bash
sandcat init --secret-provider 1password
```

This switches the mitmproxy service to
`ghcr.io/virtuslab/sandcat-mitmproxy-op`, a pre-built image that includes the
`op` CLI.

**Authentication.** The `op` CLI inside the container authenticates via a
[1Password service account](https://developer.1password.com/docs/service-accounts/).
To set one up:

1. Go to [1Password Developer Tools > Service
   Accounts](https://my.1password.com/developer-tools/infrastructure-secrets/serviceaccount/)
   and create a new service account
2. Grant it read access to the vault(s) containing your secrets
3. Add the token to `~/.config/sandcat/settings.json`:

```json
{
  "op_service_account_token": "ops_...",
  "secrets": {
    "ANTHROPIC_API_KEY": {
      "op": "op://Private/Anthropic API Key/credential",
      "hosts": ["api.anthropic.com"]
    }
  }
}
```

The token is read from the settings file by the mitmproxy addon at startup. If
`op_service_account_token` is not set in settings, the addon falls back to the
`OP_SERVICE_ACCOUNT_TOKEN` environment variable (forwarded from the host shell
into the container).

Secret resolution happens once at mitmproxy startup — run `sandcat
restart` after changing 1Password items.

## How it works internally

1. The mitmproxy container mounts `~/.config/sandcat/settings.json` (read-only)
   and the project's `.sandcat/` directory (read-only) alongside the addon
   script. The addon comes in two agent-specific variants
   (`mitmproxy_addon_claude.py`, `mitmproxy_addon_cursor.py`) that share their
   common logic via the `mitmproxy_addon_common.py` library.
2. On startup, the addon reads all available settings files (user, project,
   local), merges them according to the precedence rules above, and writes
   `sandcat.env` to the agent-facing `mitmproxy-public` shared volume
   (`/mitmproxy-public/sandcat.env`). This file contains plain env vars
   (e.g. `export GIT_USER_NAME='Your Name'`) and secret placeholders (e.g.
   `export ANTHROPIC_API_KEY=SANDCAT_PLACEHOLDER_ANTHROPIC_API_KEY`).
3. App containers mount `mitmproxy-public` read-only at `/mitmproxy-config/`.
   The shared entrypoint (`app-init.sh`) sources `sandcat.env` after installing
   the CA cert, so every process gets the env vars and placeholder values.
4. On each request, the addon first checks network access rules. If denied, the
   request is blocked with 403.
5. If allowed, the addon checks for secret placeholders in the request, verifies
   the destination host against the secret's allowlist, and either substitutes
   the real value or blocks the request with 403 (leak detection).

Real secrets never leave the mitmproxy container.

## Disabling

Remove all settings files. If no settings file exists at any layer, the addon
disables itself — no network rules are enforced and `sandcat.env` is not
written.

## Claude Code

Claude Code supports two authentication methods inside the container:

- **API key** — add an `ANTHROPIC_API_KEY` secret to `settings.json`. The
  entrypoint detects the key and seeds `~/.claude.json` with
  `{"hasCompletedOnboarding": true}` so Claude Code uses it without interactive
  setup.
- **Subscription (browser login)** — omit `ANTHROPIC_API_KEY` from
  `settings.json`. On first run Claude Code will display a URL and a code. Open
  the URL in a browser on your host machine, enter the code, and authenticate
  there — the container itself cannot open a browser.

**Autonomous mode.** The bundled `devcontainer.json` enables
`claudeCode.allowDangerouslySkipPermissions` and sets
`claudeCode.initialPermissionMode` to `bypassPermissions`. This lets Claude Code
run without interactive permission prompts inside the container. The trade-off:
sandcat already provides the security boundary (network isolation, secret
substitution, iptables kill-switch), so the in-container prompts add friction
without meaningful security benefit. Remove these settings if you prefer
interactive approval. See [Secure & Dangerous Claude Code + VS Code
Setup](https://warski.org/blog/secure-dangerous-claude-code-vs-code-setup/) for
background on this approach.

**Host customizations.** The example `compose-all.yml` bind-mounts
`~/.claude/CLAUDE.md`, `~/.claude/agents`, and `~/.claude/commands` from the
host (read-only) so your personal instructions, custom agents, and slash
commands are available inside the container. Remove any mount whose source does
not exist on your host — Docker will otherwise create an empty directory in its
place.

**Multi-line prompts.** Composing a multi-line prompt with `⌘+Enter` does not
work on macOS — the terminal reserves the `⌘` modifier and never transmits it
over the PTY, so `sandcat attach` (and Claude Code) only ever receive a plain
`Enter`. This is not sandcat-specific and cannot be fixed inside the container.
Use one of these instead:

- **`\` then `Enter`** — inserts a newline in any terminal with no setup. The
  simplest option.
- **`Option+Enter`** — Claude Code's macOS default. In Apple Terminal, first
  enable *Settings → Profiles → Keyboard → Use Option as Meta key*; iTerm2 sends
  it out of the box.
- **`Shift+Enter`** — the most familiar combination, but Claude Code only
  receives whatever bytes the terminal chooses to send for it, so it needs a
  one-time mapping in the **host** terminal. Claude Code's `/terminal-setup` is
  meant to install this, but it has two traps in this setup: it configures the
  host terminal, so running it from Claude Code *inside* the sandbox does
  nothing; and it caches an "installed" flag, so a second run reports *"already
  enabled"* even when the terminal was never actually changed. The reliable route
  is to map the key by hand:
  - **iTerm2** — Settings → Keys → Key Bindings → `+`, record `Shift+Enter`,
    choose *Send Hex Codes* and enter `0x1b 0x0d` (this is `Option+Enter`, which
    Claude Code treats as a newline). GUI bindings take effect immediately. To
    confirm it worked, run `cat -v` in the sandbox shell and press `Shift+Enter`:
    it should print `^[` instead of a blank line.
  - **VS Code integrated terminal** — add to `keybindings.json`:

    ```json
    { "key": "shift+enter",
      "command": "workbench.action.terminal.sendSequence",
      "args": { "text": "\u001b\r" },
      "when": "terminalFocus" }
    ```

## Cursor CLI

Cursor CLI support is available via `sandcat init --agent cursor`.

- The current template uses temporary compatibility defaults for auth/network:
  - **Auth passthrough via placeholder substitution.** The container sees only
    `SANDCAT_PLACEHOLDER_CURSOR_API_KEY`; the real `CURSOR_API_KEY` is injected
    by the mitmproxy addon only for allowed Cursor hosts.
  - **HTTP/1 compatibility bootstrap.** On startup, Sandcat forces
    `.network.useHttp1ForAgent = true` in Cursor CLI config to avoid known
    proxy/TLS instability with HTTP/2 streaming through mitmproxy.
  - **Proxy command defaults tuned for Cursor.** The generated proxy config uses
    the Cursor addon and keeps mitmproxy HTTP/2 enabled (`http2=true`) (plus
    streaming-safe mitmproxy
    flags such as `stream_large_bodies=1m`, `connection_strategy=lazy`,
    `anticomp=true`, and `timeout_read=300`).

    Those streaming-safe flags are **Cursor-only** — they are intentionally
    omitted on the Claude path (`sct_agent_mitm_streaming_flags`). With
    `stream_large_bodies` unset, mitmproxy buffers request bodies up to ~1 MB
    before forwarding, which lets the addon's `_substitute_secrets` run a
    body-content scan for placeholder leaks. Setting them on Claude would
    weaken that defence-in-depth check; on Cursor they are required to keep
    Connect/HTTP-2 streaming responses stable, and the body-leak check is
    instead enforced via header/URL scans plus the textual-only body-mutation
    gate (binary protobuf bodies are left untouched).
  - **Streaming detection is path-only.** The Cursor addon decides whether a
    request is streaming purely from the request path
    (`/agent.v1.AgentService/Run*`, `/aiserver.v1.RepositoryService/...`).
    A client-supplied `content-type: application/connect+proto` header alone
    is **not** sufficient — accepting it would let any request with the right
    header bypass body substitution and the placeholder leak check.
  These defaults are conservative and may be relaxed when Cursor proxy behavior
  is consistently stable across environments.
- **Authentication:** put the Cursor API key in `secrets.CURSOR_API_KEY` in
  Sandcat settings (not in `cursor.cli`). The agent container receives only
  `SANDCAT_PLACEHOLDER_CURSOR_API_KEY` via `sandcat.env`; mitmproxy substitutes
  the real key on allowed Cursor hosts (see placeholder substitution above).
  Do not use `agent login` in the sandbox unless you accept that Cursor may
  store session state under agent-home outside Sandcat's placeholder model.
- **Cursor CLI settings via Sandcat:** add a `cursor.cli` block to
  `~/.config/sandcat/settings.json` (or project `.sandcat/settings.json`) using
  the same JSON shape as Cursor's global `cli-config.json` (permissions, model,
  network flags — not API keys). Sandcat merges settings layers at mitmproxy
  startup, writes `/mitmproxy-public/cursor-cli-config.json`, and the agent
  deep-merges that fragment into `cli-config.json` in agent-home on each start.
  Sandcat-owned keys win; other Cursor-written keys in that file (model choice,
  permissions allow/deny lists, etc.) are preserved. The Cursor user template
  defaults include `cursor.cli.network.useHttp1ForAgent: true` for mitmproxy
  stability.
- `SANDCAT_MOUNT_CURSOR_CONFIG=true` mounts host Cursor config into the agent
  container. Customization paths are read-only: `AGENTS.md`, `rules/`, `skills/`,
  `commands/`, `hooks.json`, `hooks/`, `agents/`, and `mcp.json`. Runtime state
  for this sandbox is read-write on the host under
  `projects/<workspace-id>/` only (`workspaces-<project-name>` — agent
  transcripts, terminals, MCP session state). `chats/`, `plugins/`, and
  `subagents/` are not host-mounted (they live in `agent-home`). On
  `sandcat init`, missing bind sources are pre-created on the host (directories
  via `mkdir`, JSON files with minimal valid defaults, markdown files empty) so
  Docker mounts a file instead of materialising a root-owned directory.
- **Config precedence:** `~/.config/sandcat/settings.json` governs network
  allowlists, secret substitution (mitmproxy), and Sandcat-managed Cursor CLI
  settings (`cursor.cli` — not credentials). Host Cursor customization mounts
  are read-only user config. The workspace-scoped `projects/<workspace-id>/`
  mount is read-write on the host. MCP servers in `mcp.json` still need
  matching mitmproxy allowlist entries before they can reach the network from
  the sandbox.
- **Cursor CLI TLS through mitmproxy.** The Cursor CLI bundles its own Node.js
  binary with compiled-in Mozilla CA roots. Sandcat sets
  `NODE_OPTIONS=--use-openssl-ca` so the bundled Node.js uses the system CA
  store (which includes the mitmproxy CA) instead of its built-in roots.
  When Cursor honors that environment setting, mitmproxy can intercept Cursor
  API traffic and perform `SANDCAT_PLACEHOLDER_CURSOR_API_KEY` substitution
  transparently.
- Provider-specific onboarding/bootstrap logic is intentionally minimal in this
  first iteration and can be extended in project-level Dockerfile/scripts.

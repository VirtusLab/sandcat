# Cursor CLI

Cursor CLI support is available via `sandcat init --agent cursor`.

## Authentication and CLI configuration

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

## Host paths and mounts

**Cursor paths** (host `~/.cursor/`):

| Path                                                                                         | Mode       | Typical use                           |
|----------------------------------------------------------------------------------------------|------------|---------------------------------------|
| `AGENTS.md`, `rules/`, `skills/`, `commands/`, `hooks.json`, `hooks/`, `agents/`, `mcp.json` | read-only  | Shared customization                  |
| `projects/<workspace-id>/`                                                                   | read-write | This sandbox's transcripts/terminals  |

Sandcat mounts only `projects/<workspace-id>/` for the current sandbox
(`workspaces-<project-name>`), not the whole host `projects/` tree. `chats/`,
`plugins/`, and `subagents/` stay in `agent-home` so other workspaces' runtime
state is not exposed.

Cursor CLI keys Sandcat manages (`cursor.cli` in settings) are **not**
host-mounted — see the Cursor section below.

Project-local configuration (`.cursor/` in the repo) and the isolation
semantics of these mounts are described in
[Customizing optional volume mounts](../configuration/volume-mounts.md).

# GitHub Copilot CLI as a Sandcat Agent — Design

## Goal

Add GitHub's standalone `@github/copilot` CLI (`copilot` binary) as a fourth first-class agent in sandcat, alongside `claude`, `cursor`, and `codex`. `sandcat init --agent copilot ...` builds a container running Copilot CLI with the same network isolation, secret substitution, mitmproxy interception, no-new-privileges hardening, and IDE integration as the other three.

## Motivation

Users on GitHub-centric workflows want Copilot's agentic mode in a sandbox. Today they have to run it unsandboxed or bring their own container. Sandcat's per-agent architecture (introduced with the Codex integration, PR#87) is designed to absorb new agents cheaply — this is the fourth iteration.

## Non-Goals

- Copilot Chat as a **VS Code extension** without CLI backend — that runs in the IDE process, not the container, and doesn't fit sandcat's model. Users wanting only extension chat continue with vanilla dev containers.
- `gh copilot` (subcommand of `gh` CLI) — that's a suggestion helper, not an autonomous agent loop.
- Copilot Coding Agent (async GitHub-hosted agent) — different product, different architecture.
- Custom model providers via `COPILOT_PROVIDER_*` env vars (BYOK). Users can opt in manually by setting the vars in their own settings, but no first-class UX in this iteration.

## The Copilot CLI in practice

Version at spec time: `@github/copilot@1.0.79` (published Aug 2026).

**Install**: `npm install -g @github/copilot`. Node.js 20+ required. Binary lands as `copilot` on PATH.

**Auth precedence (from `copilot help environment`)**:
1. `COPILOT_GITHUB_TOKEN`
2. `GH_TOKEN`
3. `GITHUB_TOKEN`
4. Stored credentials (macOS Keychain / `~/.copilot/` on other platforms), populated by `copilot login`.

**Supported token types** (from `copilot login --help`):
- Fine-grained personal access tokens (v2 PATs) with the **"Copilot Requests"** permission
- OAuth tokens from the GitHub Copilot CLI OAuth app
- OAuth tokens from the GitHub CLI (gh) OAuth app
- ❌ Classic PATs (`ghp_...`) are **not** supported.

Every request carries `Authorization: Bearer <token>` — no internal token exchange. Same token used for every endpoint. Verified by intercepting live traffic on `2026-08-11`.

**Outbound hosts** (captured from live traffic):

| Host | Purpose |
|---|---|
| `api.github.com` | subscription check (`/copilot_internal/user`), CLI update check |
| `api.individual.githubcopilot.com` | main API — `/v1/messages` (chat), `/models`, `/mcp/readonly` |
| `telemetry.individual.githubcopilot.com` | OpenTelemetry-style usage telemetry |
| `api.business.githubcopilot.com` / `api.enterprise.githubcopilot.com` | Business / Enterprise data-residency variants (not observed in personal-tier trace) |

The subdomain (`individual` vs `business` vs `enterprise`) is selected server-side based on the token's associated subscription tier; a wildcard `*.githubcopilot.com` covers all three.

**Config directory**: `~/.copilot/` (overridable via `COPILOT_HOME`). On macOS the credential storage goes to Keychain; the JSON config in that directory is metadata only.

**MCP**: Copilot ships a built-in `github-mcp-server`. It talks to `api.individual.githubcopilot.com/mcp/readonly` — already covered by the host allowlist. No separate networking treatment needed.

## Design — the sandcat integration

Follow the existing per-agent dispatcher pattern in `cli/lib/agents.bash`. Every hook that already switches on `claude|cursor|codex` gets a `copilot` case.

### Setting schema

New user settings template `cli/templates/settings-user-copilot.json`:

```json
{
  "env": {},
  "secrets": {
    "COPILOT_GITHUB_TOKEN": {
      "value": "",
      "hosts": ["api.github.com", "*.github.com", "*.githubcopilot.com", "*.githubusercontent.com"]
    }
  },
  "network": [
    {"action": "allow", "host": "*.github.com"},
    {"action": "allow", "host": "github.com"},
    {"action": "allow", "host": "*.githubusercontent.com"},
    {"action": "allow", "host": "*.githubcopilot.com"}
  ]
}
```

Users put a fine-grained PAT (with "Copilot Requests" permission) in `secrets.COPILOT_GITHUB_TOKEN.value`. Sandcat injects `COPILOT_GITHUB_TOKEN=SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN` into the container env, Copilot CLI reads it, sends in Authorization header, mitmproxy substitutes on the wire for allowlisted hosts.

Users may alternatively supply a gh OAuth token (`gho_...`) if that's already provisioned. Both are accepted by the CLI.

### Install method

Node.js 20+ is a hard prerequisite. The base image `mcr.microsoft.com/devcontainers/base:debian` doesn't ship Node.js. The Copilot Dockerfile install block therefore:

1. Installs Node.js 22 (current LTS) via NodeSource setup script under `USER root`
2. Runs `npm install -g @github/copilot`
3. Returns to `USER vscode`

Version pin rationale for Node.js: Copilot's `engines.node` field currently allows 20+, so pinning to Node.js 22 gives runway for the CLI to raise its floor without breaking sandcat's baked image. Rebuilds pick up whatever `@github/copilot` publishes on npm at that moment.

### Config directory & optional mount

Analogous to Codex: `~/.copilot/` in-container, optional host bind-mount via `SANDCAT_MOUNT_COPILOT_CONFIG` env var (default: `true`). Sub-paths to bind (read-only):

- `$HOME/.copilot/mcp-config.json` — user's additional MCP servers
- `$HOME/.copilot/session-state/` — session persistence

Not mounted (per-container state):
- `$HOME/.copilot/config.json` — first-launch flag
- `$HOME/.copilot/logs/`
- macOS Keychain — inaccessible from Linux container anyway

### VS Code extensions

VS Code integration adds two extensions to `.devcontainer/devcontainer.json` when IDE is `vscode`:

- `GitHub.copilot` — the Copilot LSP-side completions engine
- `GitHub.copilot-chat` — the chat panel

Both share the same GitHub OAuth account inside the container. Because sandcat injects `COPILOT_GITHUB_TOKEN` env, the VS Code extension picks it up automatically without a separate sign-in step (`getSession` in the auth flow honors the env var).

### mitmproxy addon

New file `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_copilot.py`, thin wrapper:

```python
from mitmproxy_addon_common import SandcatAddon
addons = [SandcatAddon()]
```

Copilot's chat responses stream via SSE (`text/event-stream`), but the request payload is JSON and buffered `<1MB`. That's the same shape Codex uses — the default buffered-body behavior in `SandcatAddon` handles both the streaming response and the placeholder-leak scan on requests. No `stream_large_bodies` / `connection_strategy=lazy` flags needed (those are Cursor-only).

Integration test (Task 6) verifies this assumption — if SSE streaming is not tolerated by the default addon, we add the streaming flags via `sct_agent_mitm_streaming_flags`.

### RTK integration

rtk (Rust Token Killer) has no `--agent copilot` today. Copilot's config format (`~/.copilot/mcp-config.json`, `~/.copilot/settings.json`) is different from Claude/Cursor/Codex. Two options:

1. **No-op** — the `case *)` branch in `sct_rtk_user_init_block` does nothing for unknown agents. That's what happens today; keeping it means rtk installs but doesn't wire itself into Copilot. User can invoke `rtk` manually.
2. **Best-effort fallback** — try `rtk init --agent claude` since Copilot may honor Claude-style hooks. Unverified; better to skip until rtk adds real support.

**Choice**: option 1. Follows what Codex did.

## Data flow

```
~/.config/sandcat/settings.json                (or .sandcat/settings.local.json)
       │  secrets.COPILOT_GITHUB_TOKEN.value = "github_pat_..."
       ▼
sandcat init --agent copilot
       │  writes sandcat.env with:
       │    COPILOT_GITHUB_TOKEN=SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN
       │  writes Dockerfile with Copilot install block
       │  writes compose-proxy.yml with mitmproxy_addon_copilot.py
       │  writes devcontainer.json with GitHub.copilot + GitHub.copilot-chat
       ▼
sandcat run --build
       │  container starts; ENV has placeholder value
       ▼
User runs `copilot -p "..." --allow-all-tools`
       │  CLI reads COPILOT_GITHUB_TOKEN env → puts in Authorization header
       │  request to https://api.individual.githubcopilot.com/v1/messages
       ▼
mitmproxy
       │  intercepts request (host on allowlist: *.githubcopilot.com)
       │  scans placeholder in Authorization header → substitutes real token
       ▼
GitHub Copilot API answers → mitmproxy proxies response back → agent sees answer
```

## Security model

| Aspect | Same as existing agents? | Notes |
|---|---|---|
| Placeholder substitution | ✅ Yes | Bearer token in Authorization header — identical mechanism to Codex |
| Network allowlist | ✅ Yes | `*.githubcopilot.com` scope; explicit `api.github.com` for auth |
| CA trust (agent-side) | ✅ Yes | Node.js reads `NODE_EXTRA_CA_CERTS` — sandcat already sets this for Claude |
| CA trust (upstream) | ✅ Yes | Upstream cert is real (Let's Encrypt / DigiCert on github.com); mitmproxy default trust store covers it |
| No-new-privileges | ✅ Yes | Inherited from PR#90 |
| Config file leak | ⚠️ Same as Codex | If `SANDCAT_MOUNT_COPILOT_CONFIG=true` (default), user's mcp-config.json on host is bind-mounted RO. Not a token file — real tokens are in macOS Keychain, not in the mounted dir. |

## Trade-offs vs the other agents

| Aspect | Claude | Cursor | Codex | Copilot |
|---|---|---|---|---|
| Install method | Native binary (curl) | Native binary (curl) | Native binary (curl) | **npm + Node.js 22** |
| Auth secret name | ANTHROPIC_API_KEY | CURSOR_API_KEY | OPENAI_API_KEY | **COPILOT_GITHUB_TOKEN** |
| Token format | `sk-ant-...` | `key_...` | `sk-...` | **`github_pat_...` or `gho_...`** |
| Backend host | api.anthropic.com | api.cursor.sh, api2.cursor.sh | api.openai.com | ***.githubcopilot.com** |
| Streaming | Buffered JSON | HTTP/2 streaming (needs flags) | SSE, buffered | SSE, buffered (verify) |
| Config dir | ~/.claude/ | ~/.cursor/ | ~/.codex/ | **~/.copilot/** |
| VS Code ext | anthropic.claude-code | anysphere.cursor | openai.chatgpt | **GitHub.copilot + GitHub.copilot-chat** |
| Image size delta | ~30MB | ~80MB | ~30MB | **~120MB** (Node.js 22 base + copilot pkg) |

**The one meaningful cost is image size** (Node.js runtime). Everything else is per-agent glue that matches the existing pattern.

## Testing

- **bats** for the CLI dispatcher (agents.bats parametric over the four agents; composefile.bats config-volume tests; extensions.bats extension resolution).
- **Integration** in a real Docker container:
  1. `sandcat init --agent copilot` builds successfully.
  2. `docker compose up` produces a running agent container.
  3. Inside the container, `copilot --version` prints the version.
  4. With `COPILOT_GITHUB_TOKEN` in settings.json (real fine-grained PAT), `copilot -p "reply exactly PONG" --allow-all-tools` returns `PONG` and no auth errors.
  5. mitmproxy logs show the request went through, placeholder was substituted (grep for the placeholder string in the log → should NOT be forwarded; grep for the real token prefix → should).
  6. Public HTTPS still works (github.com API from a plain curl).

## Documentation

New section in README.md under existing "Agents" documentation. Content:
- One-line summary of Copilot CLI
- How to create a fine-grained PAT with "Copilot Requests" permission (github.com/settings/personal-access-tokens)
- Alternative: `COPILOT_GITHUB_TOKEN=$(gh auth token)` for quick setup
- Note on Node.js 22 install adding ~120MB to image
- Link to Copilot CLI docs

Also update `cli/README.md` supported-agents list.

## Global Constraints

- Setting: `secrets.COPILOT_GITHUB_TOKEN` with hosts `["api.github.com", "*.github.com", "*.githubcopilot.com", "*.githubusercontent.com"]`.
- Env var name in container: `COPILOT_GITHUB_TOKEN` (matches CLI's own precedence).
- Placeholder: `SANDCAT_PLACEHOLDER_COPILOT_GITHUB_TOKEN`.
- Install method: NodeSource setup + `npm install -g @github/copilot` — pinned to Node.js 22.
- Config directory: `~/.copilot/`, optional bind-mount gated by `SANDCAT_MOUNT_COPILOT_CONFIG` (default true, mirrors other agents).
- VS Code extensions when IDE is vscode: `GitHub.copilot`, `GitHub.copilot-chat`.
- mitmproxy addon: default buffered-body — no streaming flags — pending Task 6 verification. If verification fails, adopt Cursor-style streaming flags for copilot only.
- No RTK integration in v1 (rtk lacks `--agent copilot`).
- Backwards compatible: `sandcat init` with an existing project or `--agent claude|cursor|codex` unchanged.

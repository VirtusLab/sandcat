# Codex agent — design spec

**Date:** 2026-08-03
**Status:** Draft (pending user review)
**Related:** builds on the per-agent dispatch pattern established by `claude` and `cursor` in `cli/lib/agents.bash`; extends the rtk feature (PR #83) with a `codex` case.

## Summary

Add [OpenAI Codex CLI](https://github.com/openai/codex) as a third first-class agent in sandcat, alongside `claude` and `cursor`. Codex is a Rust-based coding CLI that talks to `api.openai.com` (Chat Completions REST) and reads its config from `~/.codex/`. Sandcat wires it end-to-end: install into the image, secret substitute `OPENAI_API_KEY` at the mitmproxy layer, bind-mount user customization files read-only, auto-configure the rtk hook.

## Motivation

Sandcat currently supports `claude` and `cursor`. Codex has an established user base among OpenAI subscribers (ChatGPT Plus/Pro/Business/Enterprise plans) and its own CLI/VS Code extension surface. Adding it as a first-class agent gives OpenAI-based teams the same secure sandbox experience — network isolation, secret substitution, deterministic build, rtk token compression — with zero manual setup beyond dropping their API key into sandcat settings.

## Non-goals

- **ChatGPT sign-in flow.** First iteration supports only `OPENAI_API_KEY` (matches how claude/cursor handle auth). Users who want ChatGPT sign-in can run `codex login` manually inside the container; sandcat does not add the extra hosts (`chatgpt.com`, `auth.openai.com`, `*.chatgpt.com`) to the allowlist for that flow. Follow-up iteration if there is demand.
- **Codex VS Code extension MCP integration.** Extension is installed via `devcontainer.json.customizations`, but any additional MCP wiring the extension expects (custom settings, hooks) is out of scope for this spec.
- **Auto-updates inside the sandbox.** `codex update` is not exercised. Users get the current codex release by rebuilding the image (`sandcat run --build`), consistent with sandcat's rebuild-to-upgrade philosophy.
- **Codex-specific sandcat features that don't apply.** No cursor-style `cli-config.json` merge — codex config lives under `~/.codex/` inside the agent-home volume and is user-managed.

## Architecture

### Dispatch surface (`cli/lib/agents.bash`)

`sct_available_agents` extended to `"claude cursor codex"`. Every existing `sct_agent_*` case dispatcher gets a new `codex)` arm. Full table:

| Function | codex arm |
|---|---|
| `sct_agent_mount_env_var` | `SANDCAT_MOUNT_CODEX_CONFIG` |
| `sct_agent_host_config_paths` | `$HOME/.codex/AGENTS.md`, `$HOME/.codex/skills/`, `$HOME/.codex/commands/` |
| `sct_agent_api_key_help` | `OPENAI_API_KEY   your OpenAI API key (for Codex CLI)` |
| `sct_agent_op_api_key_help` | `OPENAI_API_KEY   "op": "op://vault/OpenAI API Key/credential"` |
| `sct_agent_post_user_settings_hook` | no-op (`return 0`) — nothing agent-specific to seed |
| `sct_agent_vscode_extension` | `openai.chatgpt` |
| `sct_agent_devcontainer_settings_block` | empty (no forced VS Code settings for codex) |
| `sct_agent_compose_environment_entries` | empty (no forced env vars) |
| `sct_agent_docker_install_block` | see [Installation](#installation) below |
| `sct_agent_docker_home_prep_block` | `mkdir -p /home/vscode/.codex` + `alias codex-yolo="codex --yolo"` in `.bashrc` |
| `sct_agent_mitm_streaming_flags` | empty (codex uses plain HTTP/1.1 REST + SSE; body buffering enables placeholder leak check) |
| `sct_agent_user_init_block` | idempotent bootstrap; see [User init](#user-init) below |

### Installation

Codex ships as a Rust binary via `install.sh`. The script's default install locations both sit under `$HOME`:

```sh
BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
```

The binary at `$BIN_DIR/codex` is a **symlink** to `$CODEX_HOME/packages/standalone/current/codex`. Sandcat's `agent-home` volume masks `/home/vscode/*` on upgrade, which would break both the symlink and its target if we accepted the defaults.

**Fix:** force both to system paths at install time (Dockerfile ENV), so the binary and its target both live outside the volume mount.

Emitted `sct_agent_docker_install_block` for codex:

```dockerfile
# Install Codex CLI (OpenAI). CODEX_INSTALL_DIR and CODEX_HOME point at
# system paths only for the install.sh invocation so the resolved
# symlink target survives the agent-home volume mask on upgrade. The
# env vars go on the `sh` end of the pipe (not `curl`) so install.sh
# actually sees them; using inline `VAR=val` prefix (not `ENV`) keeps
# them out of the image environment. At runtime CODEX_HOME is unset,
# so codex reads user config from ~/.codex/ (agent-home, per-sandbox).
USER root
RUN curl -fsSL https://chatgpt.com/codex/install.sh | \
    CODEX_INSTALL_DIR=/usr/local/bin CODEX_HOME=/opt/codex-home sh
USER vscode
```

This mirrors the rtk `/usr/local/bin` approach (PR #83 fix round 2). Note: `ENV` would leak `CODEX_HOME=/opt/codex-home` into runtime, redirecting user config away from agent-home; inline `VAR=val` before `sh` scopes it to that single command.

### User init

Emitted `sct_agent_user_init_block` for codex:

```bash
# Codex CLI is installed at build time (Dockerfile.app).
# Basic health check on first start; failure is non-fatal.
if command -v codex >/dev/null 2>&1; then
    codex --version >/dev/null 2>&1 || echo "sandcat: codex --version failed (non-fatal)" >&2
fi
```

Codex reads `$OPENAI_API_KEY` from the environment at runtime; `sandcat.env` (sourced by app-init.sh) already exports the placeholder or 1Password-resolved value based on the user's settings. No agent-specific config file needs to be seeded, unlike claude's onboarding flag or cursor's cli-config.json merge.

### Settings template

New file: `cli/templates/settings-user-codex.json`.

```json
{
  "env": {},
  "secrets": {
    "OPENAI_API_KEY": {
      "value": "",
      "hosts": ["api.openai.com"]
    },
    "GITHUB_TOKEN": {
      "value": "",
      "hosts": ["github.com", "*.github.com", "*.githubusercontent.com"]
    }
  },
  "network": [
    {"action": "allow", "host": "*.github.com"},
    {"action": "allow", "host": "github.com"},
    {"action": "allow", "host": "*.githubusercontent.com"},
    {"action": "allow", "host": "api.openai.com"}
  ]
}
```

Only `api.openai.com` in the allowlist — no `chatgpt.com`, no `auth.openai.com`. Users who want ChatGPT sign-in add those manually (out of scope for first iteration).

### mitmproxy addon

New file: `cli/templates/devcontainer/sandcat/scripts/mitmproxy_addon_codex.py`. Structurally identical to `mitmproxy_addon_claude.py` — codex uses OpenAI's REST API (Chat Completions endpoint, plain JSON, HTTP/1.1 with SSE streaming for responses). No Connect/HTTP-2 or streaming-safe workarounds needed — the buffered-body model that lets the common addon do placeholder leak checks on request payloads applies here directly.

Dispatch in `cli/lib/devcontainer.bash` (~line 195):

```bash
case "$agent" in
    cursor)
        mitm_addon_file="mitmproxy_addon_cursor.py"
        mitm_http2="true"
        ;;
    codex)
        mitm_addon_file="mitmproxy_addon_codex.py"
        mitm_http2="true"
        ;;
    claude|*)
        mitm_addon_file="mitmproxy_addon_claude.py"
        mitm_http2="true"
        ;;
esac
```

### rtk integration

**Integration-test finding (T10):** rtk 0.44 does not support `--agent codex`; the separate `--codex` flag cannot be combined with `--hook-only` or `--auto-patch`. Auto-init is not wired.

The `codex)` case was reverted from `sct_rtk_user_init_block` (`cli/lib/rtk.bash`). Codex falls through to the `*)` no-op, the same as any unknown agent. The rtk binary is still installed agent-agnostically via `sct_rtk_docker_install_block`, so users can invoke `rtk` commands manually inside the container.

Host-side workaround: run `rtk init --codex` interactively on the host once — the resulting `~/AGENTS.md` and `~/.codex/AGENTS.md` are picked up by codex through the host bind-mount.

## User-facing behavior

### Init

```bash
sandcat init --agent codex --ide vscode
```

Interactive picker also lists `codex` (from the extended `sct_available_agents`).

### API key setup

Sandcat's `create_user_settings` copies `settings-user-codex.json` on first init if `~/.config/sandcat/settings.json` does not exist. User fills in `OPENAI_API_KEY.value`:

```json
"secrets": {
  "OPENAI_API_KEY": {
    "value": "sk-real-openai-key",
    "hosts": ["api.openai.com"]
  }
}
```

Or via 1Password:

```bash
sandcat init --agent codex --secret-provider 1password ...
# settings.json.secrets.OPENAI_API_KEY.op = "op://vault/OpenAI API Key/credential"
```

Inside the container, `$OPENAI_API_KEY = SANDCAT_PLACEHOLDER_OPENAI_API_KEY`; mitmproxy substitutes the real value on outbound requests to `api.openai.com` and blocks it (403) on any other destination.

### Running

```bash
sandcat run                           # drop to shell
codex "explain this codebase to me"
codex-yolo "run tests and fix failures"   # alias for codex --yolo
codex exec "list all TODOs"               # non-interactive one-shot mode
```

`codex --yolo` (alias for `--dangerously-bypass-approvals-and-sandbox`) is codex's own built-in escape hatch; sandcat provides `codex-yolo` as a bash alias for parity with `claude-yolo`.

### Host config sharing

Optional customization files on the host, bind-mounted read-only into the container:

- `~/.codex/AGENTS.md` — global agent instructions (codex convention, similar to `~/.claude/CLAUDE.md` and `~/.cursor/AGENTS.md`)
- `~/.codex/skills/` — reusable skills
- `~/.codex/commands/` — custom slash commands

`ensure_host_agent_config_paths codex` pre-creates any missing paths on the host with minimal content so Docker doesn't materialize them as root-owned. Rest of `~/.codex/` (`config.toml`, `.credentials.json`, `history.jsonl`, `log/`, `packages/`) lives in the container's `agent-home` volume — per-sandbox persistent, per-sandbox isolated.

**Opt-out from host mounts:** `SANDCAT_MOUNT_CODEX_CONFIG=false sandcat init --agent codex ...` — every `~/.codex/` path lives only in agent-home volume, no host coupling.

### rtk integration behavior

The `rtk` binary is installed in every codex sandbox (agent-agnostic). Auto-init is not wired: rtk 0.44 does not support `--agent codex`, and `--codex` cannot combine with `--hook-only` or `--auto-patch`. Codex users who want rtk instructions should run `rtk init --codex` interactively on the host once; the resulting `~/AGENTS.md` and `~/.codex/AGENTS.md` are picked up via the host bind-mount.

### Init summary

```
Initialization complete.
  ...
  Devcontainer:     .devcontainer/
  Gitignore:        added Sandcat block
  RTK:              installed (disable with --features no-rtk)

Next steps:
  Edit ~/.config/sandcat/settings.json to add your API keys:
    OPENAI_API_KEY   your OpenAI API key (for Codex CLI)
    GITHUB_TOKEN     a GitHub personal access token (for git push, gh cli)
  Then run: sandcat run, or reopen the project using the dev container
```

## Testing

### Unit (bats)

**Extend `cli/test/agents/agents.bats`** — add `codex:` arm to every 3-input contract test (currently `claude / cursor / unknown`). Concretely:

- `sct_available_agents lists claude, cursor and codex`
- `sct_is_valid_agent accepts codex`
- `sct_agent_mount_env_var: codex → SANDCAT_MOUNT_CODEX_CONFIG`
- `sct_agent_host_config_paths: codex → AGENTS.md + skills + commands`
- `sct_agent_api_key_help: codex → OPENAI_API_KEY`
- `sct_agent_op_api_key_help: codex → OpenAI API Key op reference`
- `sct_agent_vscode_extension: codex → openai.chatgpt`
- `sct_agent_docker_install_block: codex → CODEX_INSTALL_DIR + CODEX_HOME + install.sh`
- `sct_agent_docker_home_prep_block: codex → mkdir + codex-yolo alias`
- `sct_agent_user_init_block: codex → codex --version bootstrap`
- `sct_agent_mitm_streaming_flags: codex returns empty (buffered body, no streaming flags)`

**Extend `cli/test/rtk/rtk.bats`:**

- `sct_rtk_user_init_block: codex emits guarded rtk init --agent codex`
- `sct_rtk_user_init_block: codex emits nothing when disabled (SANDCAT_RTK=false)`

**Extend `cli/test/init/init.bats`:**

- `init accepts --agent codex`
- `init creates codex user settings on first run`
- `init pre-creates host paths for codex config mount`
- `init skips host pre-creation when SANDCAT_MOUNT_CODEX_CONFIG=false`

**Extend interactive stubs** — every `stub select_option` for `Select agent:` needs `codex` appended so the pattern match still works.

### Integration (executed hands-on after implementation, container-side)

1. **Fresh install path:** `sandcat init --agent codex --ide vscode` → `sandcat run --build` → in container: `command -v codex` = `/usr/local/bin/codex`; `codex --version` OK; `codex-yolo --version` OK (alias resolves).
2. **API key substitution:** set `OPENAI_API_KEY.value` in host `~/.config/sandcat/settings.json`, restart proxy → in container `env | grep OPENAI_API_KEY` returns the placeholder; `codex exec "hello"` succeeds (request to `api.openai.com` gets substituted key at proxy).
3. **rtk auto-init:** after first start, `~/.codex/config.toml` contains a rtk hook entry (`grep 'rtk hook codex' ~/.codex/config.toml` succeeds); restart → no re-init warning (idempotent).
4. **VS Code extension:** with `--ide vscode`, open in devcontainer; verify `openai.chatgpt` extension is installed.
5. **Host mount opt-out:** `SANDCAT_MOUNT_CODEX_CONFIG=false sandcat init` — verify no bind-mount lines for codex in generated `compose-all.yml`; container starts, `~/.codex/` fully writable in agent-home.
6. **Regression:** run existing claude and cursor init flows to confirm no `sct_available_agents` extension broke the two-agent world.

## Rollback plan

Trivial. Feature is purely additive:

- Agent selection is opt-in (`--agent codex` explicit).
- New files are net-additions.
- New `case` arms in existing dispatchers don't touch claude/cursor branches.

Revert the feature commit to remove.

## Open questions

None at design-approval time. Decisions locked:

- Auth: `OPENAI_API_KEY` only (Non-goals covers ChatGPT sign-in deferral)
- Mounts: claude-style (AGENTS.md, skills/, commands/ read-only)
- Install path: `/usr/local/bin` + `/opt/codex-home` (system-wide, upgrade-safe)
- mitmproxy addon: separate file `mitmproxy_addon_codex.py`, claude-style buffered-body model
- rtk: wired in this iteration, no host caveat needed
- Alias: `codex-yolo` in `.bashrc` for parity with `claude-yolo`

## Follow-ups (not in this spec)

- ChatGPT sign-in flow (add `chatgpt.com`, `auth.openai.com`, `*.chatgpt.com`) if user demand appears.
- Auto-configure the OpenAI VS Code extension's own settings if it exposes any that sandcat should manage.
- Codex `config.toml` presets (e.g. `sandbox = "workspace-write"` as a sandcat-managed default) if we find repeatable-value patterns.

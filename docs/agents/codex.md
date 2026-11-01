# Codex CLI

Sandcat installs [OpenAI's Codex CLI](https://github.com/openai/codex)
into every codex-agent sandbox and wires `OPENAI_API_KEY` through the
mitmproxy secret substitution layer. Codex reads its config from
`~/.codex/config.toml` (per-sandbox, agent-home volume). You can
authenticate with an API key or a ChatGPT subscription — see
[Authentication](#authentication).

**Setup:**

```bash
sandcat init --agent codex --ide vscode
# Edit ~/.config/sandcat/settings.json — set secrets.OPENAI_API_KEY.value
sandcat run
codex "explain this codebase"
```

**Bash alias:** `codex-yolo` (= `codex --yolo`) is available in every
codex sandbox for parity with `claude-yolo`.

**Host config sharing** (optional, default on): `~/.codex/AGENTS.md`,
`~/.codex/skills/`, and `~/.codex/commands/` are bind-mounted read-only
from the host into the container, matching how `~/.claude/` is handled.
The rest of `~/.codex/` (config.toml, credentials, history) lives in
the container's agent-home volume — per-sandbox persistent, per-sandbox
isolated. Opt out with `SANDCAT_MOUNT_CODEX_CONFIG=false`.

## Authentication

Codex supports API-key and ChatGPT subscription authentication:

- **API key:** Set `secrets.OPENAI_API_KEY.value` in `settings.json`.
- **ChatGPT subscription:** Run `codex login --device-auth` in the sandbox. Open the URL on your host, enter the one-time code, and verify with `codex login status`. Use device login because the regular browser flow requires a callback the host browser cannot reach. If device-code login isn’t available for your account or workspace, enable it in ChatGPT security settings or ask your workspace admin.

If subscription login is being ignored, remove the `OPENAI_API_KEY` entry from `~/.config/sandcat/settings.json` and restart the sandbox.

# Codex CLI

Sandcat installs [OpenAI's Codex CLI](https://github.com/openai/codex)
into every codex-agent sandbox and wires `OPENAI_API_KEY` through the
mitmproxy secret substitution layer. Codex reads its config from
`~/.codex/config.toml` (per-sandbox, agent-home volume) and picks up
the API key directly from the environment — no `codex login` required.

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

**Auth model:** first iteration supports `OPENAI_API_KEY` only.
ChatGPT sign-in (`chatgpt.com` / `auth.openai.com`) is not in the
default allowlist — users who want that flow can add the hosts to
`.sandcat/settings.local.json` and run `codex login` manually inside
the container.

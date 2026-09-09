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

**RTK integration:** works out of the box. On first container start,
sandcat seeds `~/.codex/AGENTS.md` (from the host bind-mount if
present) and runs `rtk init -g --codex` to write `~/.codex/RTK.md`
and add an `@RTK.md` reference to `AGENTS.md`. Idempotent: skipped
once the reference is already there. Disable with `--features
no-rtk` or `SANDCAT_RTK=false`.

Note: because rtk needs to patch a writable `AGENTS.md`, sandcat
mounts the host's `~/.codex/AGENTS.md` at `~/.codex-host/AGENTS.md`
(a helper path) — the user-init step copies it into the writable
`~/.codex/AGENTS.md`. Host edits to `AGENTS.md` take effect after a
`docker compose down -v` (or manual rm inside). Skills and commands
directories are bind-mounted normally at `~/.codex/skills` and
`~/.codex/commands`, so those live-reload as usual.

**Auth model:** first iteration supports `OPENAI_API_KEY` only.
ChatGPT sign-in (`chatgpt.com` / `auth.openai.com`) is not in the
default allowlist — users who want that flow can add the hosts to
`.sandcat/settings.local.json` and run `codex login` manually inside
the container.

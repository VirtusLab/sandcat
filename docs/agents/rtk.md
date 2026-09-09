# RTK — LLM token compression

[rtk-ai/rtk](https://github.com/rtk-ai/rtk) ("Rust Token Killer") wraps
shell commands invoked by AI agents and compresses their output before
the agent reads it, cutting token consumption 60-90% on typical dev
commands (test runs, grep output, build logs). `sandcat init` installs
the `rtk` binary into every sandbox by default and wires the agent
hook so the agent picks it up automatically. Setup differs slightly
per agent — see below.

**Opt out** if you'd rather run without it (e.g. debugging a shell
command's raw output):

```bash
sandcat init --features no-rtk ...
SANDCAT_RTK=false sandcat init ...
```

Both are equivalent — the env var is the scripted counterpart of the
interactive/CSV feature flag. When disabled, the rtk binary is not
installed into the image and no init hook is emitted for any agent.

## Per-agent setup

| Agent | Setup |
|-------|-------|
| Claude Code | zero configuration — see [Claude Code → RTK hook](claude.md#rtk-hook) |
| Cursor CLI | one-time host-side hook — see [Cursor CLI → RTK hook](cursor.md#rtk-hook) |
| Codex CLI | wired automatically at init — see [Codex CLI](codex.md) |
| GitHub Copilot CLI | wired automatically at init — see [GitHub Copilot CLI](copilot.md) |

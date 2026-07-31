# rtk default install — design spec

**Date:** 2026-07-30
**Status:** Draft (pending user review)
**Related:** `feat/gitignore-defaults` (PR #82) established the `--features no-<name>` + `SANDCAT_<NAME>` opt-out pattern reused here.

## Summary

Install [rtk-ai/rtk](https://github.com/rtk-ai/rtk) (Rust Token Killer — a CLI shell-command output compressor that reduces LLM token consumption 60-90%) into every sandcat sandbox by default, with an opt-out flag. Auto-initialize the rtk hook for the selected agent so it works out of the box. First iteration supports only `claude`; the dispatch structure is designed for trivial extension to `cursor` / `codex` / others later.

## Motivation

Sandcat is a developer sandbox aimed at running AI coding agents. rtk reduces the token cost of every non-trivial shell command (grep output, test runs, build logs) that an agent executes inside the sandbox. Installing it by default gives every sandcat user this cost reduction with zero configuration, while a clean opt-out honors setups where rtk isn't wanted (regulated environments, users who prefer raw output, etc.).

## Non-goals

- **Codex support.** The user asked about codex specifically, but codex is not currently an agent in sandcat (`sct_available_agents` returns `claude cursor` only). This spec scopes rtk to `claude` and leaves cursor/codex/others as follow-up work.
- **Devbox/Nix packaging.** rtk isn't on nixhub yet. We install via the official install.sh script (same pattern sandcat uses for claude and cursor).
- **Reproducible builds via pinning.** First iteration pulls from `master` via install.sh; if pinning becomes important (e.g. a broken upstream release), we add a `SCT_RTK_VERSION` constant later.
- **Protecting user-edited `~/.claude/settings.json`.** rtk init's own merge behavior handles this; sandcat does not add extra guardrails.

## Architecture

### New file: `cli/lib/rtk.bash`

Single-purpose module with three functions:

```bash
# Returns 0 iff SANDCAT_RTK is not "false" (default: enabled).
sct_rtk_enabled() { [[ "${SANDCAT_RTK:-true}" != "false" ]]; }

# Emits the Dockerfile RUN block that installs rtk globally.
# Empty when the feature is disabled.
sct_rtk_docker_install_block() { ... }

# Emits the per-agent app-user-init.sh fragment that runs `rtk init`
# idempotently. Empty when disabled or when the agent has no rtk profile.
sct_rtk_user_init_block() { local agent=$1; ... }
```

### Modified: `cli/lib/agents.bash`

The existing `sct_agent_docker_install_block` and `sct_agent_user_init_block` dispatchers append the rtk fragment (when enabled) to their per-agent output. rtk installation itself is agent-agnostic (one binary for all agents), but the `rtk init` command is per-agent — hence rtk's user-init block lives in `rtk.bash` but is invoked from `agents.bash`.

### Modified: `cli/libexec/init/init`

- Read `SANDCAT_RTK` env var (default `true`).
- Add `"no-rtk (do not install rtk shell hook)"` to `available_features[]` (interactive picker) and to the CSV feature parser (`--features no-rtk`).
- `no-rtk` in either channel sets `rtk_enabled=false` and exports `SANDCAT_RTK=false` so downstream Dockerfile/user-init emission sees it.
- Extend the unknown-feature error message to list `no-rtk`.
- Extend init summary with a `RTK:` line (`installed` / `disabled`).

### Data flow

```
sandcat init [--features no-rtk] [SANDCAT_RTK=false]
  │
  ▼
init.bash: parse features/env → export SANDCAT_RTK
  │
  ▼
devcontainer.bash: generate .devcontainer/*
  ├─ Dockerfile.app: sct_agent_docker_install_block "$agent"
  │     └─ appends sct_rtk_docker_install_block  (RUN curl … install.sh | sh)
  │        [emitted only when sct_rtk_enabled]
  │
  └─ app-user-init.sh: sct_agent_user_init_block "$agent"
        └─ appends sct_rtk_user_init_block "$agent"  (guarded rtk init -g)
           [emitted only when sct_rtk_enabled AND agent has rtk profile]
```

## User-facing behavior

### Defaults

rtk installed and initialized for `claude` **by default**. Zero configuration.

### Opt-out (two equivalent channels)

```bash
sandcat init --features no-rtk               # flag
SANDCAT_RTK=false sandcat init               # env var
```

Also composes: `sandcat init --features tui,no-shared-cache,no-rtk`.

### Interactive picker

New entry appended:

```
Select optional features (comma-separated numbers, empty for none):
  1) tui (mitmproxy console instead of web UI)
  2) no-shared-cache (per-project dep cache instead of shared)
  3) no-gitignore (do not append Sandcat block to .gitignore)
  4) no-rtk (do not install rtk shell hook)
```

### Init summary

```
Initialization complete.
  ...
  Gitignore:        added Sandcat block
  RTK:              installed (disable with --features no-rtk)
```

Alternative states: `disabled` (opt-out).

### Runtime behavior in the container

- **Build-time (Dockerfile.app):** `RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | RTK_INSTALL_DIR=/usr/local/bin sh` — only when enabled. Installed to `/usr/local/bin/` (not `~/.local/bin/`) so an existing agent-home volume from a pre-rtk build cannot mask the binary on upgrade. Binary baked into the image.
- **Container start (app-user-init.sh):** Idempotency-guarded `rtk init -g --hook-only --auto-patch` for `claude`. Skipped once the rtk hook string is present in `~/.claude/settings.json`. Uses `--hook-only` to avoid writing to `~/.claude/CLAUDE.md`, which sandcat bind-mounts read-only (EROFS).
- **Error handling:** rtk init failure logs a non-fatal warning to stderr; container startup proceeds. rtk is a convenience layer — its failure must not block dev workflow.
- **User-owned `~/.claude/settings.json`:** rtk init merges its hook with existing content — that behavior is rtk's, not sandcat's.

## Emitted fragments (concrete text)

**Dockerfile.app** (when `sct_rtk_enabled`):

```dockerfile
# Install rtk (Rust Token Killer) — compresses shell command output so AI
# agents consume fewer tokens per command. Installed system-wide so the
# agent-home volume can't mask the binary on upgrade. Disable at init
# time with `sandcat init --features no-rtk` or `SANDCAT_RTK=false`.
USER root
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | RTK_INSTALL_DIR=/usr/local/bin sh
USER vscode
```

**app-user-init.sh** for `claude` (when `sct_rtk_enabled` and agent has profile):

```bash
# rtk (Rust Token Killer) — one-time hook config for Claude Code.
# `rtk init -g --hook-only --auto-patch` patches ~/.claude/settings.json
# with the PreToolUse hook non-interactively; --hook-only skips writing
# RTK.md (sandcat mounts ~/.claude/CLAUDE.md read-only, so rtk's default
# CLAUDE.md injection would EROFS).
# Idempotency: skipped once the hook string is already present.
if command -v rtk >/dev/null 2>&1 && ! grep -q '"command": "rtk hook' "$HOME/.claude/settings.json" 2>/dev/null; then
    rtk init -g --hook-only --auto-patch >/dev/null 2>&1 \
        || echo "sandcat: rtk init failed (non-fatal)" >&2
fi
```

`command -v rtk` guard is defensive: if a user rebuilt from an old image without rtk (feature was OFF at build), we skip cleanly instead of erroring on missing binary. The `grep` idempotency guard checks `settings.json` directly (not `config.toml`) because `--hook-only` does not create `~/.config/rtk/config.toml`.

## Extensibility (future agents)

Adding rtk for a new agent requires only a new case in `sct_rtk_user_init_block`:

```bash
sct_rtk_user_init_block() {
    local agent=$1
    sct_rtk_enabled || return 0
    case "$agent" in
        claude)
            cat <<'EOF'
if command -v rtk >/dev/null 2>&1 && ! grep -q '"command": "rtk hook' "$HOME/.claude/settings.json" 2>/dev/null; then
    rtk init -g --hook-only --auto-patch >/dev/null 2>&1 \
        || echo "sandcat: rtk init failed (non-fatal)" >&2
fi
EOF
            ;;
        # cursor)  # future
        #     ... rtk init -g --agent cursor ...
        #     ;;
        # codex)   # future
        #     ... rtk init -g --agent codex ...
        #     ;;
        *)
            # No rtk profile for this agent yet — safe no-op.
            ;;
    esac
}
```

No changes required in `Dockerfile.app` (binary is agent-agnostic) or in the init CLI (feature flag is the same).

### Behavior on agents without an rtk profile

The install RUN is gated only by `sct_rtk_enabled`, not by agent — so on `--agent cursor` today, rtk **is** installed into the image, but `rtk init` is **not** auto-run (cursor case is not wired). The binary sits on PATH; users can invoke `rtk init -g --agent cursor` manually. This trades a small amount of build time for a much simpler extension path when the cursor/codex cases are wired: only the `sct_rtk_user_init_block` case needs updating, no image rebuild logic to change.

## Testing

### Unit (bats)

**New `cli/test/rtk/rtk.bats`:**
- `sct_rtk_enabled` returns 0 when `SANDCAT_RTK` is unset, `true`, or empty
- `sct_rtk_enabled` returns 1 when `SANDCAT_RTK=false`
- `sct_rtk_docker_install_block` emits the install.sh RUN line when enabled
- `sct_rtk_docker_install_block` emits nothing when disabled
- `sct_rtk_user_init_block claude` contains `rtk init -g` with both guards
- `sct_rtk_user_init_block <unknown>` emits nothing (safe default)

**Extend `cli/test/init/init.bats`:**
- `init --features no-rtk` → summary reads `RTK:` line as `disabled`; `SANDCAT_RTK=false` exported to sub-command
- `SANDCAT_RTK=false init` → equivalent behavior
- Default `init` → summary reads `RTK:` line as `installed`
- Interactive picker stub list includes the `no-rtk` label
- Unknown-feature error message lists `no-rtk` alongside `tui`, `no-shared-cache`, `no-gitignore`

### Integration (executed hands-on after implementation, container-side)

Every scenario below runs against a real `docker compose` sandbox.

1. **Fresh install path:** `sandcat init --agent claude` on scratch project → `sandcat run --build` → inside container: `command -v rtk` succeeds; `~/.claude/settings.json` contains an rtk hook entry; `~/.config/rtk/config.toml` exists.
2. **Restart idempotency:** exit, `sandcat run` again (no rebuild) → the guarded `rtk init -g` is skipped; `settings.json` unchanged.
3. **Opt-out at init:** `sandcat init --features no-rtk` → `sandcat run --build` → `command -v rtk` fails; `settings.json` has no rtk hook; container starts cleanly.
4. **Upgrade path:** container built pre-feature (no rtk) → `sandcat init` in same project (rtk feature now available) → `sandcat run --build` → rtk appears; hook lands in `settings.json`.
5. **Un-opting:** after (3), `sandcat init` without the flag → rebuild → rtk installed and initialized again.

## Rollback plan

Rollback is trivial: `sandcat init --features no-rtk` on any project removes rtk from the next rebuild. For a full removal of the feature from sandcat: revert the feature commit; nothing in this design creates state outside the sandbox container's own volume.

## Open questions

None at design-approval time.

## Follow-ups (not in this spec)

- Add `cursor` case to `sct_rtk_user_init_block` (needs `rtk init -g --agent cursor` verified against rtk's actual CLI).
- Add `codex` agent to sandcat (separate large feature), then rtk case for it.
- Consider pinning rtk to a specific version if upstream `master` becomes unstable.

#!/usr/bin/env bash
# rtk (Rust Token Killer, https://github.com/rtk-ai/rtk) install + init
# helpers. Emission is gated on SANDCAT_RTK (default: true). Consumed by
# the per-agent dispatchers in cli/lib/agents.bash so the rtk install RUN
# lands in Dockerfile.app and rtk init runs at container start.

# Returns 0 (enabled) when SANDCAT_RTK is unset or anything other than
# the literal string "false". Default-on posture: absent env var means
# the user has not explicitly opted out.
sct_rtk_enabled() {
	[[ "${SANDCAT_RTK:-true}" != "false" ]]
}

# Emits the Dockerfile.app RUN block that installs the rtk binary
# globally via its official install script. Agent-agnostic — the same
# binary serves every supported agent; per-agent hook wiring happens
# at container start via sct_rtk_user_init_block.
#
# Emits an empty output when the feature is disabled so the caller can
# unconditionally append it to Dockerfile fragments.
sct_rtk_docker_install_block() {
	sct_rtk_enabled || return 0
	cat <<'EOF'
# Install rtk (Rust Token Killer) — compresses shell command output so AI
# agents consume fewer tokens per command. Installed system-wide so the
# agent-home volume can't mask the binary on upgrade. Disable at init
# time with `sandcat init --features no-rtk` or `SANDCAT_RTK=false`.
USER root
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | RTK_INSTALL_DIR=/usr/local/bin sh
USER vscode
EOF
}

# Emits the app-user-init.sh fragment that runs `rtk init` for the given
# agent, guarded to a one-time execution. Currently wires `claude` and
# `cursor`; unknown/future agents (including codex — rtk 0.44 does not
# support `--agent codex`, and `--codex` cannot combine with `--hook-only`
# or `--auto-patch`) get a safe no-op so the binary is still available on
# PATH but rtk stays uninitialized until the case is added.
#
# Emits an empty output when the feature is disabled OR when the agent
# has no rtk profile.
#
# Args:
#   $1 - Agent name
sct_rtk_user_init_block() {
	local agent=$1
	sct_rtk_enabled || return 0
	case "$agent" in
		claude)
			cat <<'EOF'
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
EOF
			;;
		cursor)
			cat <<'EOF'
# rtk (Rust Token Killer) — one-time hook config for Cursor CLI.
# The hook lives in ~/.cursor/hooks.json, which sandcat bind-mounts
# read-only from the host (SANDCAT_MOUNT_CURSOR_CONFIG=true default).
# Expected workflow: user runs `rtk init -g --hook-only --auto-patch \
# --agent cursor` on the HOST once — then this guard's grep passes and
# the init below stays a no-op. If the guard doesn't pass here, we
# still try inside the container so the warning nudges the user to
# initialize rtk on the host.
if command -v rtk >/dev/null 2>&1 && ! grep -q '"rtk hook cursor' "$HOME/.cursor/hooks.json" 2>/dev/null; then
    rtk init -g --hook-only --auto-patch --agent cursor >/dev/null 2>&1 \
        || echo "sandcat: rtk hook not found for cursor. Install rtk on your host and run once: rtk init -g --hook-only --auto-patch --agent cursor  (see README RTK section)" >&2
fi
EOF
			;;
		*)
			# No rtk profile wired for this agent — safe no-op. Binary is
			# still installed by sct_rtk_docker_install_block; user can
			# invoke `rtk init` manually.
			return 0
			;;
	esac
}

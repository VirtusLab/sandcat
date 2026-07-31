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
# agents consume fewer tokens per command. Disable at init time with
# `sandcat init --features no-rtk` or `SANDCAT_RTK=false`.
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh
EOF
}

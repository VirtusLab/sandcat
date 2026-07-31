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
